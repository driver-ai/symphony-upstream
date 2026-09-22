defmodule SymphonyElixir.Linear.AgentTool do
  @moduledoc "Provider-native Linear tools exposed to Codex app-server turns."

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.ReviewOperation
  require Logger

  @raw_tool "linear_graphql"
  @typed_tools ~w(symphony_review linear_read linear_comment linear_attach_pr linear_transition)

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    if review_enabled?(opts),
      do: execute_review_tool(tool, arguments, opts),
      else: execute_legacy_tool(tool, arguments, opts)
  end

  @spec tool_specs() :: [map()]
  def tool_specs, do: tool_specs(nil)

  @spec tool_specs(map() | nil) :: [map()]
  def tool_specs(%{enabled: true}), do: typed_tool_specs()

  def tool_specs(_) do
    [
      spec(
        @raw_tool,
        "Execute a raw GraphQL operation against Linear.",
        %{
          "query" => string_schema(),
          "variables" => %{"type" => ["object", "null"], "additionalProperties" => true}
        },
        ["query"]
      )
    ]
  end

  defp typed_tool_specs do
    [
      spec("symphony_review", "Control the runtime-bound review run.", %{"operation" => enum_schema(~w(start status resume cancel)), "run_id" => nullable_string_schema()}, ["operation"]),
      spec(
        "linear_read",
        "Read bounded Linear context.",
        %{"operation" => enum_schema(~w(issue comments document workflow_states)), "id" => nullable_string_schema(), "cursor" => nullable_string_schema()},
        ["operation"]
      ),
      spec(
        "linear_comment",
        "Create, update, or reply on the active issue.",
        comment_properties(),
        ["operation", "body"]
      ),
      spec("linear_attach_pr", "Attach a GitHub PR from the bound repository.", %{"url" => string_schema(), "title" => nullable_string_schema()}, ["url"]),
      spec("linear_transition", "Move the active issue to a state from its bound team.", %{"state_id" => string_schema()}, ["state_id"])
    ]
  end

  defp spec(name, description, properties, required) do
    %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => properties, "required" => required}}
  end

  defp string_schema, do: %{"type" => "string", "minLength" => 1}
  defp nullable_string_schema, do: %{"type" => ["string", "null"]}
  defp enum_schema(values), do: %{"type" => "string", "enum" => values}

  defp comment_properties do
    %{
      "operation" => enum_schema(~w(create update reply)),
      "body" => string_schema(),
      "comment_id" => nullable_string_schema(),
      "parent_id" => nullable_string_schema()
    }
  end

  defp review_enabled?(opts), do: match?(%{enabled: true}, Keyword.get(opts, :review))

  defp execute_review_tool(@raw_tool, _arguments, _opts), do: failure("`linear_graphql` is disabled for review-enabled sessions; use typed Linear tools.")

  defp execute_review_tool(tool, arguments, opts) when tool in @typed_tools and is_map(arguments) do
    with :ok <- validate_arguments(tool, arguments),
         :ok <- validate_context(opts),
         {:ok, result} <- dispatch_typed(tool, arguments, opts) do
      success(result)
    else
      {:error, reason} -> failure(format_error(reason))
    end
  end

  defp execute_review_tool(tool, _arguments, _opts), do: failure("Unsupported or invalid dynamic tool #{inspect(tool)}.", @typed_tools)

  defp dispatch_typed("symphony_review", args, opts) do
    operation = args["operation"]
    run_id = args["run_id"]

    with {:ok, issue} <- fetch_authoritative_issue(opts) do
      ReviewOperation.execute(operation, run_id, review_context(issue, opts), Keyword.fetch!(opts, :review))
    end
  end

  defp dispatch_typed("linear_read", args, opts) do
    id = args["id"]

    case args["operation"] do
      "issue" -> graphql(issue_query(), %{id: bound_issue_id(opts)}, opts)
      "comments" -> graphql(comments_query(), %{id: bound_issue_id(opts), after: args["cursor"]}, opts)
      "document" when is_binary(id) -> read_linked_document(id, opts)
      "workflow_states" -> graphql(states_query(), %{id: bound_issue_id(opts)}, opts)
      _ -> {:error, :invalid_linear_read_operation}
    end
  end

  defp dispatch_typed("linear_comment", args, opts) do
    case args["operation"] do
      "create" -> graphql(comment_create_mutation(), %{issueId: bound_issue_id(opts), body: args["body"]}, opts)
      "reply" -> reply_to_comment(args, opts)
      "update" -> update_owned_comment(args, opts)
    end
  end

  defp dispatch_typed("linear_attach_pr", args, opts) do
    with :ok <- validate_pr_repository(args["url"], opts) do
      graphql(attach_pr_mutation(), %{issueId: bound_issue_id(opts), url: args["url"], title: args["title"]}, opts)
    end
  end

  defp dispatch_typed("linear_transition", args, opts) do
    with {:ok, response} <- graphql(states_query(), %{id: bound_issue_id(opts)}, opts),
         {:ok, state} <- find_state(response, args["state_id"]),
         :ok <- maybe_verify_handoff(state, opts) do
      graphql(transition_mutation(), %{id: bound_issue_id(opts), stateId: args["state_id"]}, opts)
    end
  end

  defp maybe_verify_handoff(state, opts) do
    normalized = state["name"] |> to_string() |> String.trim() |> String.downcase()
    active_states = Keyword.fetch!(opts, :tracker_settings).active_states |> Enum.map(&String.downcase/1)

    if state["type"] == "completed" or normalized in ~w(merging) or normalized == "in review" or
         (normalized not in active_states and normalized != "blocked" and state["type"] not in ~w(backlog canceled)) do
      with {:ok, issue} <- fetch_authoritative_issue(opts),
           {:ok, result} <- ReviewOperation.execute("verify", nil, review_context(issue, opts), Keyword.fetch!(opts, :review)),
           true <- complete_result?(result, opts[:repository]) or {:error, :review_incomplete} do
        :ok
      else
        {:error, reason} ->
          Logger.warning("Review handoff rejected issue_id=#{bound_issue_id(opts)} issue_identifier=#{Map.get(opts[:issue], :identifier)} session_id=#{opts[:session_id]}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp complete_result?(%{"event" => "result", "status" => "complete", "evidence" => evidence}, repository) when is_map(evidence) do
    string_fields = ~w(plan_revision plan_hash repository base head context_fingerprint method_fingerprint config_fingerprint)

    Enum.all?(string_fields, &(is_binary(evidence[&1]) and evidence[&1] != "")) and
      evidence["repository"] == repository and match?([_ | _], evidence["receipts"]) and
      Enum.all?(evidence["receipts"], fn receipt ->
        is_map(receipt) and is_binary(receipt["path"]) and receipt["path"] != "" and
          is_binary(receipt["sha256"]) and Regex.match?(~r/^[a-f0-9]{64}$/, receipt["sha256"])
      end)
  end

  defp complete_result?(_result, _repository), do: false

  defp reply_to_comment(%{"parent_id" => parent_id, "body" => body}, opts) when is_binary(parent_id) do
    with {:ok, response} <- graphql(comment_membership_query(), %{id: parent_id}, opts),
         true <- get_in(response, ["data", "comment", "issue", "id"]) == bound_issue_id(opts) or {:error, :comment_not_on_bound_issue} do
      graphql(comment_reply_mutation(), %{issueId: bound_issue_id(opts), parentId: parent_id, body: body}, opts)
    end
  end

  defp reply_to_comment(_args, _opts), do: {:error, :missing_parent_id}

  defp update_owned_comment(%{"comment_id" => comment_id, "body" => body}, opts) when is_binary(comment_id) do
    with {:ok, response} <- graphql(comment_membership_query(), %{id: comment_id}, opts),
         true <- get_in(response, ["data", "comment", "issue", "id"]) == bound_issue_id(opts) or {:error, :comment_not_on_bound_issue},
         true <-
           (is_binary(get_in(response, ["data", "viewer", "id"])) and
              get_in(response, ["data", "comment", "user", "id"]) ==
                get_in(response, ["data", "viewer", "id"])) or
             {:error, :comment_not_owned_by_agent} do
      graphql(comment_update_mutation(), %{id: comment_id, body: body}, opts)
    end
  end

  defp update_owned_comment(_args, _opts), do: {:error, :missing_comment_id}

  defp fetch_authoritative_issue(opts) do
    with {:ok, response} <- graphql(issue_query(), %{id: bound_issue_id(opts)}, opts),
         issue when is_map(issue) <- get_in(response, ["data", "issue"]),
         true <- issue["id"] == bound_issue_id(opts) do
      {:ok, issue}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :bound_issue_not_found}
    end
  end

  defp review_context(issue, opts),
    do: %{
      issue: issue,
      workspace: Keyword.fetch!(opts, :workspace),
      repository: Keyword.fetch!(opts, :repository),
      thread_id: Keyword.fetch!(opts, :thread_id),
      session_id: Keyword.fetch!(opts, :session_id)
    }

  defp bound_issue_id(opts), do: opts[:issue].id

  defp validate_context(opts) do
    issue = opts[:issue]
    fields = [:workspace, :repository, :thread_id, :session_id]

    if is_map(issue) and is_binary(Map.get(issue, :id)) and Map.get(issue, :id) != "" and
         Enum.all?(fields, &(is_binary(opts[&1]) and opts[&1] != "")) and
         Path.type(opts[:workspace]) == :absolute and is_map(opts[:tracker_settings]) and is_list(Map.get(opts[:tracker_settings], :active_states)) do
      :ok
    else
      {:error, :missing_bound_context}
    end
  end

  defp read_linked_document(id, opts) do
    with {:ok, issue} <- fetch_authoritative_issue(opts),
         {:ok, response} <- graphql(document_query(), %{id: id}, opts),
         document when is_map(document) <- get_in(response, ["data", "document"]),
         true <- linked_document?(document, issue) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :document_not_linked_to_bound_issue}
    end
  end

  defp linked_document?(document, issue) do
    get_in(document, ["issue", "id"]) == issue["id"] or
      (is_binary(document["url"]) and document["url"] != "" and
         String.contains?(issue["description"] || "", document["url"]))
  end

  defp graphql(query, variables, opts) do
    client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    client_opts = Keyword.take(opts, [:tracker_settings])

    case client.(query, variables, client_opts) do
      {:ok, %{"errors" => [_ | _]}} -> {:error, :linear_graphql_error}
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_legacy_tool(@raw_tool, arguments, opts) do
    with {:ok, query, variables} <- normalize_raw_arguments(arguments),
         {:ok, response} <- legacy_client(opts).(query, variables, Keyword.take(opts, [:tracker_settings])) do
      legacy_graphql_response(response)
    else
      {:error, reason} -> response(false, legacy_error_payload(reason))
    end
  end

  defp execute_legacy_tool(tool, _arguments, _opts),
    do: response(false, %{"error" => %{"message" => "Unsupported dynamic tool: #{inspect(tool)}.", "supportedTools" => [@raw_tool]}})

  defp legacy_client(opts), do: Keyword.get(opts, :linear_client, &Client.graphql/3)

  defp legacy_graphql_response(payload) do
    success =
      case payload do
        %{"errors" => [_ | _]} -> false
        %{errors: [_ | _]} -> false
        _ -> true
      end

    response(success, payload)
  end

  defp legacy_error_payload(:missing_query), do: %{"error" => %{"message" => "`linear_graphql` requires a non-empty `query` string."}}
  defp legacy_error_payload(:invalid_arguments), do: %{"error" => %{"message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."}}
  defp legacy_error_payload(:invalid_variables), do: %{"error" => %{"message" => "`linear_graphql.variables` must be a JSON object when provided."}}
  defp legacy_error_payload(:missing_linear_api_token), do: %{"error" => %{"message" => "Symphony is missing Linear auth. Set `tracker.provider.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."}}
  defp legacy_error_payload({:linear_api_status, status}), do: %{"error" => %{"message" => "Linear GraphQL request failed with HTTP #{status}.", "status" => status}}
  defp legacy_error_payload({:linear_api_request, reason}), do: %{"error" => %{"message" => "Linear GraphQL request failed before receiving a successful response.", "reason" => inspect(reason)}}
  defp legacy_error_payload(reason), do: %{"error" => %{"message" => "Linear GraphQL tool execution failed.", "reason" => inspect(reason)}}

  defp normalize_raw_arguments(arguments) when is_binary(arguments), do: if(String.trim(arguments) == "", do: {:error, :missing_query}, else: {:ok, String.trim(arguments), %{}})

  defp normalize_raw_arguments(arguments) when is_map(arguments) do
    query = arguments["query"] || arguments[:query]
    variables = arguments["variables"] || arguments[:variables] || %{}

    cond do
      not is_binary(query) or String.trim(query) == "" -> {:error, :missing_query}
      not is_map(variables) -> {:error, :invalid_variables}
      true -> {:ok, String.trim(query), variables}
    end
  end

  defp normalize_raw_arguments(_arguments), do: {:error, :invalid_arguments}

  defp validate_arguments(tool, arguments) do
    schema = Enum.find(typed_tool_specs(), &(&1["name"] == tool))["inputSchema"]
    properties = schema["properties"]

    valid =
      Enum.all?(schema["required"], &Map.has_key?(arguments, &1)) and
        Enum.all?(arguments, fn {key, value} -> valid_argument?(properties[key], value) end)

    if valid, do: :ok, else: {:error, :invalid_tool_arguments}
  end

  defp valid_argument?(nil, _value), do: false
  defp valid_argument?(%{"enum" => values}, value), do: value in values
  defp valid_argument?(%{"type" => "string"}, value), do: is_binary(value) and String.trim(value) != ""
  defp valid_argument?(%{"type" => ["string", "null"]}, value), do: is_nil(value) or (is_binary(value) and value != "")

  defp find_state(response, state_id) do
    case Enum.find(get_in(response, ["data", "issue", "team", "states", "nodes"]) || [], &(&1["id"] == state_id)) do
      nil -> {:error, :state_not_in_bound_team}
      state -> {:ok, state}
    end
  end

  defp validate_pr_repository(url, opts) do
    with %URI{scheme: "https", host: "github.com", path: path, userinfo: nil, query: nil, fragment: nil, port: 443} <- URI.parse(url),
         [owner, repo, "pull", number] <- String.split(String.trim(path, "/"), "/"),
         {number, ""} when number > 0 <- Integer.parse(number),
         true <-
           String.downcase(owner <> "/" <> repo) == Keyword.fetch!(opts, :repository) or
             {:error, :pr_repository_mismatch} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_pr_url}
    end
  end

  defp success(payload), do: response(true, payload)
  defp failure(message, supported \\ @typed_tools), do: response(false, %{"error" => %{"message" => message, "supportedTools" => supported}})

  defp response(success, payload) do
    output = if is_map(payload) or is_list(payload), do: Jason.encode!(payload, pretty: true), else: inspect(payload)
    %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp format_error(reason) when is_atom(reason), do: "Tool execution rejected: #{reason}"
  defp format_error(_reason), do: "Tool execution rejected by the runtime; inspect runtime logs for details."

  defp issue_query,
    do:
      "query SymphonyBoundIssue($id: String!) { issue(id: $id) { id identifier title description state { id name type } project { id name slugId url } documents { nodes { id title url } } attachments { nodes { id title url sourceType } } relations { nodes { id type relatedIssue { id identifier title state { name } } } } } }"

  defp comments_query,
    do:
      "query SymphonyBoundComments($id: String!, $after: String) { issue(id: $id) { id comments(first: 50, after: $after) { nodes { id body createdAt updatedAt parent { id } user { id name } } pageInfo { hasNextPage endCursor } } } }"

  defp document_query, do: "query SymphonyLinkedDocument($id: String!) { document(id: $id) { id title content url updatedAt issue { id } } }"
  defp states_query, do: "query SymphonyBoundStates($id: String!) { issue(id: $id) { id team { id states { nodes { id name type } } } } }"
  defp comment_membership_query, do: "query SymphonyBoundComment($id: String!) { viewer { id } comment(id: $id) { id issue { id } user { id } } }"
  defp comment_create_mutation, do: "mutation SymphonyCreateComment($issueId: String!, $body: String!) { commentCreate(input: {issueId: $issueId, body: $body}) { success comment { id url } } }"

  defp comment_reply_mutation,
    do:
      "mutation SymphonyReplyComment($issueId: String!, $parentId: String!, $body: String!) { commentCreate(input: {issueId: $issueId, parentId: $parentId, body: $body}) { success comment { id url } } }"

  defp comment_update_mutation, do: "mutation SymphonyUpdateComment($id: String!, $body: String!) { commentUpdate(id: $id, input: {body: $body}) { success comment { id url } } }"

  defp attach_pr_mutation,
    do:
      "mutation SymphonyAttachPR($issueId: String!, $url: String!, $title: String) { attachmentLinkGitHubPR(issueId: $issueId, url: $url, title: $title, linkKind: links) { success attachment { id url title } } }"

  defp transition_mutation, do: "mutation SymphonyTransition($id: String!, $stateId: String!) { issueUpdate(id: $id, input: {stateId: $stateId}) { success issue { id state { id name type } } } }"
end
