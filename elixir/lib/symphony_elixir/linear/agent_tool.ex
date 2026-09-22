defmodule SymphonyElixir.Linear.AgentTool do
  @moduledoc "Provider-native Linear tools exposed to Codex app-server turns."

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.ReviewOperation

  @raw_tool "linear_graphql"
  @typed_tools ~w(symphony_review linear_read linear_comment linear_attach_pr linear_transition)
  @protected_state_names ["in review", "merging", "done"]

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    if review_enabled?(opts), do: execute_review_tool(tool, arguments, opts), else: execute_legacy_tool(tool, arguments, opts)
  end

  @spec tool_specs(map() | nil) :: [map()]
  def tool_specs(review \\ nil)
  def tool_specs(%{enabled: true}), do: typed_tool_specs()

  def tool_specs(_) do
    [spec(@raw_tool, "Execute a raw GraphQL operation against Linear.", %{
      "query" => string_schema(),
      "variables" => %{"type" => ["object", "null"], "additionalProperties" => true}
    }, ["query"])]
  end

  defp typed_tool_specs do
    [
      spec("symphony_review", "Control the runtime-bound review run.", %{"operation" => enum_schema(~w(start status resume cancel)), "run_id" => nullable_string_schema()}, ["operation"]),
      spec("linear_read", "Read bounded Linear context.", %{"operation" => enum_schema(~w(issue comments document workflow_states)), "id" => nullable_string_schema(), "cursor" => nullable_string_schema()}, ["operation"]),
      spec("linear_comment", "Create, update, or reply on the active issue.", %{"operation" => enum_schema(~w(create update reply)), "body" => string_schema(), "comment_id" => nullable_string_schema(), "parent_id" => nullable_string_schema()}, ["operation", "body"]),
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
  defp review_enabled?(opts), do: match?(%{enabled: true}, Keyword.get(opts, :review))

  defp execute_review_tool(@raw_tool, _arguments, _opts), do: failure("`linear_graphql` is disabled for review-enabled sessions; use typed Linear tools.")

  defp execute_review_tool(tool, arguments, opts) when tool in @typed_tools and is_map(arguments) do
    with :ok <- reject_extra_fields(tool, arguments),
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

    with true <- operation in ~w(start status resume cancel) or {:error, :invalid_review_operation},
         {:ok, issue} <- fetch_authoritative_issue(opts),
         {:ok, result} <- review_module(opts).execute(operation, run_id, review_context(issue, opts), Keyword.fetch!(opts, :review)) do
      {:ok, result}
    end
  end

  defp dispatch_typed("linear_read", args, opts) do
    case args["operation"] do
      "issue" -> graphql(issue_query(), %{id: bound_issue_id(opts)}, opts)
      "comments" -> graphql(comments_query(), %{id: bound_issue_id(opts), after: args["cursor"]}, opts)
      "document" when is_binary(args["id"]) -> graphql(document_query(), %{id: args["id"]}, opts)
      "workflow_states" -> graphql(states_query(), %{id: bound_issue_id(opts)}, opts)
      _ -> {:error, :invalid_linear_read_operation}
    end
  end

  defp dispatch_typed("linear_comment", args, opts) do
    case args["operation"] do
      "create" -> graphql(comment_create_mutation(), %{issueId: bound_issue_id(opts), body: args["body"]}, opts)
      "reply" -> reply_to_comment(args, opts)
      "update" -> update_owned_comment(args, opts)
      _ -> {:error, :invalid_linear_comment_operation}
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
         :ok <- maybe_verify_handoff(state, opts),
         {:ok, result} <- graphql(transition_mutation(), %{id: bound_issue_id(opts), stateId: args["state_id"]}, opts) do
      {:ok, result}
    end
  end

  defp dispatch_typed(_tool, _args, _opts), do: {:error, :unsupported_tool}

  defp maybe_verify_handoff(state, opts) do
    normalized = state["name"] |> to_string() |> String.trim() |> String.downcase()

    if normalized in @protected_state_names or state["type"] == "completed" do
      with {:ok, issue} <- fetch_authoritative_issue(opts),
           {:ok, result} <- review_module(opts).execute("verify", nil, review_context(issue, opts), Keyword.fetch!(opts, :review)),
           true <- complete_result?(result) or {:error, {:review_incomplete, result["reason"]}} do
        :ok
      end
    else
      :ok
    end
  end

  defp complete_result?(%{"event" => "result", "status" => "complete", "evidence" => evidence}) when is_map(evidence) do
    Enum.all?(~w(plan_revision plan_hash repository base head context_fingerprint method_fingerprint config_fingerprint receipts), &Map.has_key?(evidence, &1))
  end

  defp complete_result?(_result), do: false

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
           get_in(response, ["data", "comment", "user", "id"]) ==
             get_in(response, ["data", "viewer", "id"]) or
             {:error, :comment_not_owned_by_agent} do
      graphql(comment_update_mutation(), %{id: comment_id, body: body}, opts)
    end
  end

  defp update_owned_comment(_args, _opts), do: {:error, :missing_comment_id}

  defp fetch_authoritative_issue(opts) do
    with {:ok, response} <- graphql(issue_query(), %{id: bound_issue_id(opts)}, opts),
         issue when is_map(issue) <- get_in(response, ["data", "issue"]) do
      {:ok, issue}
    else
      nil -> {:error, :bound_issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_context(issue, opts), do: %{issue: issue, workspace: Keyword.fetch!(opts, :workspace), thread_id: Keyword.fetch!(opts, :thread_id), session_id: Keyword.fetch!(opts, :session_id)}
  defp review_module(opts), do: Keyword.get(opts, :review_module, ReviewOperation)

  defp bound_issue_id(opts) do
    case Keyword.fetch!(opts, :issue) do
      %{native_ref: %{"id" => id}} when is_binary(id) -> id
      %{native_ref: %{id: id}} when is_binary(id) -> id
      %{id: id} when is_binary(id) -> id
    end
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
    success = case payload do
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

  defp reject_extra_fields(tool, arguments) do
    allowed = case tool do
      "symphony_review" -> ~w(operation run_id)
      "linear_read" -> ~w(operation id cursor)
      "linear_comment" -> ~w(operation body comment_id parent_id)
      "linear_attach_pr" -> ~w(url title)
      "linear_transition" -> ~w(state_id)
    end
    if Enum.all?(Map.keys(arguments), &(&1 in allowed)), do: :ok, else: {:error, :unexpected_tool_argument}
  end

  defp find_state(response, state_id) do
    case Enum.find(get_in(response, ["data", "issue", "team", "states", "nodes"]) || [], &(&1["id"] == state_id)) do
      nil -> {:error, :state_not_in_bound_team}
      state -> {:ok, state}
    end
  end

  defp validate_pr_repository(url, opts) do
    with %URI{host: "github.com", path: path} <- URI.parse(url),
         [owner, repo, "pull", number] <- String.split(String.trim(path, "/"), "/"),
         {_number, ""} <- Integer.parse(number),
         true <-
           String.downcase(owner <> "/" <> repo) ==
             repository_from_workspace(Keyword.fetch!(opts, :workspace)) or
             {:error, :pr_repository_mismatch} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_pr_url}
    end
  end

  defp repository_from_workspace(workspace) do
    case System.cmd("git", ["-C", workspace, "config", "--get", "remote.origin.url"], stderr_to_stdout: true) do
      {remote, 0} ->
        remote
        |> String.trim()
        |> String.replace(~r{^(?:https://github\.com/|git@github\.com:)}, "")
        |> String.trim_trailing(".git")
        |> String.downcase()

      {_output, _status} ->
        nil
    end
  end

  defp success(payload), do: response(true, payload)
  defp failure(message, supported \\ @typed_tools), do: response(false, %{"error" => %{"message" => message, "supportedTools" => supported}})
  defp response(success, payload) do
    output = if is_map(payload) or is_list(payload), do: Jason.encode!(payload, pretty: true), else: inspect(payload)
    %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp format_error(:missing_query), do: "`linear_graphql` requires a non-empty `query` string."
  defp format_error(:invalid_variables), do: "`linear_graphql.variables` must be a JSON object when provided."
  defp format_error(:invalid_arguments), do: "`linear_graphql` expects a query string or an object with `query` and optional `variables`."
  defp format_error(reason), do: "Tool execution rejected: #{inspect(reason)}"

  defp issue_query, do: "query SymphonyBoundIssue($id: String!) { issue(id: $id) { id identifier title description state { id name type } project { id name slugId url } attachments { nodes { id title url sourceType } } relations { nodes { id type relatedIssue { id identifier title state { name } } } } } }"
  defp comments_query, do: "query SymphonyBoundComments($id: String!, $after: String) { issue(id: $id) { id comments(first: 50, after: $after) { nodes { id body createdAt updatedAt parent { id } user { id name } } pageInfo { hasNextPage endCursor } } } }"
  defp document_query, do: "query SymphonyLinkedDocument($id: String!) { document(id: $id) { id title content url updatedAt } }"
  defp states_query, do: "query SymphonyBoundStates($id: String!) { issue(id: $id) { id team { id states { nodes { id name type } } } } }"
  defp comment_membership_query, do: "query SymphonyBoundComment($id: String!) { viewer { id } comment(id: $id) { id issue { id } user { id } } }"
  defp comment_create_mutation, do: "mutation SymphonyCreateComment($issueId: String!, $body: String!) { commentCreate(input: {issueId: $issueId, body: $body}) { success comment { id url } } }"
  defp comment_reply_mutation, do: "mutation SymphonyReplyComment($issueId: String!, $parentId: String!, $body: String!) { commentCreate(input: {issueId: $issueId, parentId: $parentId, body: $body}) { success comment { id url } } }"
  defp comment_update_mutation, do: "mutation SymphonyUpdateComment($id: String!, $body: String!) { commentUpdate(id: $id, input: {body: $body}) { success comment { id url } } }"
  defp attach_pr_mutation, do: "mutation SymphonyAttachPR($issueId: String!, $url: String!, $title: String) { attachmentLinkGitHubPR(issueId: $issueId, url: $url, title: $title, linkKind: links) { success attachment { id url title } } }"
  defp transition_mutation, do: "mutation SymphonyTransition($id: String!, $stateId: String!) { issueUpdate(id: $id, input: {stateId: $stateId}) { success issue { id state { id name type } } } }"
end
