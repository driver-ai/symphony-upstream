defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlugs: [String!]!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {in: $projectSlugs}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        project {
          id
          name
          slugId
          url
        }
        assignee {
          id
        }
        delegate {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $projectSlugs: [String!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}, project: {slugId: {in: $projectSlugs}}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        project {
          id
          name
          slugId
          url
        }
        assignee {
          id
        }
        delegate {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    case normalized_states do
      [] ->
        {:ok, []}

      states ->
        with {:ok, tracker} <- configured_tracker_for_read(),
             {:ok, routing_filters} <- routing_filters() do
          do_fetch_by_states(tracker.project_slug, states, routing_filters)
        end
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, tracker} <- configured_tracker_for_read(),
             {:ok, routing_filters} <- routing_filters() do
          do_fetch_issue_states(ids, tracker.project_slug, routing_filters)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)

    request_fun =
      Keyword.get(opts, :request_fun, fn request_payload, headers ->
        post_graphql_request(request_payload, headers, tracker_settings.endpoint)
      end)

    with {:ok, headers} <- graphql_headers(tracker_settings),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    normalize_issue_for_test(issue, assignee, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil, String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee, delegate) when is_map(issue) do
    normalize_issue(issue, %{
      assignee: routing_filter_for_test(assignee),
      delegate: routing_filter_for_test(delegate)
    })
  end

  defp routing_filter_for_test(value) when is_binary(value) do
    case build_assignee_filter(value) do
      {:ok, filter} -> filter
      {:error, _reason} -> nil
    end
  end

  defp routing_filter_for_test(_value), do: nil

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, ["test-project"], nil, graphql_fun)
    end
  end

  defp do_fetch_by_states(project_slugs, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slugs, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(project_slugs, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlugs: project_slugs,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slugs, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, project_slugs, assignee_filter) do
    do_fetch_issue_states(ids, project_slugs, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, project_slugs, assignee_filter, graphql_fun)
       when is_list(ids) and is_list(project_slugs) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, project_slugs, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _project_slugs, _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, project_slugs, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           projectSlugs: project_slugs,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response_strict(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)

          do_fetch_issue_states_page(
            rest_ids,
            project_slugs,
            assignee_filter,
            graphql_fun,
            updated_acc,
            issue_order_index
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers(tracker_settings) do
    case tracker_settings.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers, endpoint) do
    Req.post(endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(response, assignee_filter) do
    decode_linear_response(response, assignee_filter, :drop_malformed)
  end

  defp decode_linear_response_strict(response, assignee_filter) do
    decode_linear_response(response, assignee_filter, :error_on_malformed)
  end

  defp decode_linear_response(
         %{"data" => %{"issues" => %{"nodes" => nodes}}},
         assignee_filter,
         malformed_policy
       )
       when is_list(nodes) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))

    malformed_count = Enum.count(issues, &is_nil/1)

    case {malformed_policy, malformed_count > 0} do
      {:error_on_malformed, true} ->
        {:error, :linear_unknown_payload}

      {:drop_malformed, true} ->
        Logger.warning("Dropping malformed Linear issue records count=#{malformed_count}")
        {:ok, Enum.reject(issues, &is_nil/1)}

      {:drop_malformed, false} ->
        {:ok, issues}

      {_, false} ->
        {:ok, issues}
    end
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter, _malformed_policy) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter, _malformed_policy) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, routing_filters) when is_map(issue) do
    state_name = get_in(issue, ["state", "name"])

    if Enum.all?([issue["id"], issue["identifier"], issue["title"], state_name], &present_string?/1) do
      assignee = issue["assignee"]
      delegate = issue["delegate"]
      blockers = extract_blockers(issue)

      %Issue{
        id: issue["id"],
        identifier: issue["identifier"],
        title: issue["title"],
        description: issue["description"],
        priority: parse_priority(issue["priority"]),
        state: state_name,
        branch_name: issue["branchName"],
        url: issue["url"],
        assignee_id: assignee_field(assignee, "id"),
        delegate_id: assignee_field(delegate, "id"),
        project: normalize_project(issue["project"]),
        blocked_by: blockers,
        labels: extract_labels(issue),
        dispatchable: dispatchable?(state_name, blockers, assignee, delegate, routing_filters),
        created_at: parse_datetime(issue["createdAt"]),
        updated_at: parse_datetime(issue["updatedAt"])
      }
    end
  end

  defp normalize_issue(_issue, _routing_filters), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  # The project is context for prompts and hooks, never a validity requirement: an issue without
  # one stays a valid record with `project: nil`.
  defp normalize_project(%{"id" => id} = project) when is_binary(id) and id != "" do
    %{id: id, name: project["name"], slug_id: project["slugId"], url: project["url"]}
  end

  defp normalize_project(_project), do: nil

  # Linear hands an issue to an agent through `delegate` and keeps a person as `assignee`, so an
  # agent worker routes on `tracker.delegate` while a human-account worker routes on `tracker.assignee`.
  # Each configured filter must match; an unset filter matches anything.
  defp dispatchable?(state_name, blockers, assignee, delegate, routing_filters) do
    assigned_to_worker?(assignee, routing_filter(routing_filters, :assignee)) and
      assigned_to_worker?(delegate, routing_filter(routing_filters, :delegate)) and
      not blocked_before_dispatch?(state_name, blockers)
  end

  defp routing_filter(%{} = routing_filters, key) when is_atom(key), do: Map.get(routing_filters, key)
  defp routing_filter(_routing_filters, _key), do: nil

  defp blocked_before_dispatch?(state_name, blockers)
       when is_binary(state_name) and is_list(blockers) do
    normalize_state_name(state_name) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          not terminal_state?(blocker_state)

        _ ->
          true
      end)
  end

  defp blocked_before_dispatch?(_state_name, _blockers), do: false

  defp terminal_state?(state_name) when is_binary(state_name) do
    terminal_states =
      Config.settings!().tracker.terminal_states
      |> Enum.map(&normalize_state_name/1)
      |> MapSet.new()

    MapSet.member?(terminal_states, normalize_state_name(state_name))
  end

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_filters do
    tracker = Config.settings!().tracker

    with {:ok, assignee_filter} <- build_routing_filter(tracker.assignee),
         {:ok, delegate_filter} <- build_routing_filter(tracker.delegate) do
      {:ok, %{assignee: assignee_filter, delegate: delegate_filter}}
    end
  end

  defp build_routing_filter(nil), do: {:ok, nil}
  defp build_routing_filter(value) when is_binary(value), do: build_assignee_filter(value)

  defp configured_tracker_for_read do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) -> {:error, :missing_linear_api_token}
      not (is_list(tracker.project_slug) and tracker.project_slug != []) -> {:error, :missing_linear_project_slug}
      true -> {:ok, tracker}
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
