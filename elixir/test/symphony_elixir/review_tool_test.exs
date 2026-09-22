defmodule SymphonyElixir.ReviewToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.AgentTool
  alias SymphonyElixir.ReviewRunnerFixture

  setup do
    root = Path.join(System.tmp_dir!(), "review-tools-#{System.unique_integer([:positive])}")
    review = ReviewRunnerFixture.create!(root)
    issue_id = "issue-#{System.unique_integer([:positive])}"
    issue = %{"id" => issue_id, "identifier" => "SYM-100", "description" => "current plan"}

    {:ok, api} =
      Agent.start_link(fn ->
        %{
          issue: issue,
          calls: [],
          state: %{"id" => "state-1", "name" => "In Review", "type" => "started"},
          comment_issue: issue_id,
          author: "agent",
          viewer: "agent",
          document: %{"id" => "doc-1", "url" => "https://linear.app/team/document/doc-1", "issue" => %{"id" => issue_id}}
        }
      end)

    opts = [
      review: review,
      issue: %Issue{id: issue_id, identifier: "SYM-100"},
      workspace: review.workspace,
      repository: "driver-ai/runtime",
      thread_id: "thread-1",
      session_id: "session-1",
      tracker_settings: %{active_states: ["Todo", "In Progress"]},
      linear_client: fn query, variables, _opts -> query(api, query, variables) end
    ]

    on_exit(fn -> File.rm_rf(root) end)
    %{opts: opts, api: api, review: review}
  end

  test "fresh completed evidence authorizes the actual bound team's handoff", c do
    assert call(c, "symphony_review", %{operation: "start"})["success"]
    assert call(c, "linear_transition", %{state_id: "state-1"})["success"]
    assert transition_count(c) == 1
    [start, verify] = ReviewRunnerFixture.calls(c.review.state_root)
    assert start["issue"]["id"] == c.opts[:issue].id
    assert verify["operation"] == "verify"
    assert verify["execution"] == %{"workspace" => c.review.workspace, "repository" => "driver-ai/runtime", "thread_id" => "thread-1", "session_id" => "session-1"}
  end

  test "missing, incomplete, changed-plan and mismatched evidence cannot hand off", c do
    File.write!(Path.join(c.review.workspace, "success.json"), ~s({"status":"complete"}))
    refute call(c, "linear_transition", %{state_id: "state-1"})["success"]
    assert call(c, "symphony_review", %{operation: "start"})["success"]

    for options <- [
          %{mode: "incomplete"},
          %{mode: "unknown"},
          %{mode: "running"},
          %{head: "new-published-head"},
          %{evidence: %{head: ""}},
          %{evidence: %{plan_hash: ""}},
          %{evidence: %{repository: "other/repository"}},
          %{evidence: %{receipts: []}},
          %{evidence: %{receipts: [%{path: "x", sha256: "forged"}]}},
          %{result_envelope: %{run_id: "other-run"}},
          %{exit_status: 7}
        ] do
      ReviewRunnerFixture.configure!(c.review.state_root, options)
      refute call(c, "linear_transition", %{state_id: "state-1"})["success"], inspect(options)
    end

    ReviewRunnerFixture.configure!(c.review.state_root, %{})
    Agent.update(c.api, &put_in(&1.issue["description"], "changed plan"))
    refute call(c, "linear_transition", %{state_id: "state-1"})["success"]
    assert List.last(ReviewRunnerFixture.calls(c.review.state_root))["issue"]["description"] == "changed plan"
    assert transition_count(c) == 0
  end

  test "renamed handoffs and completed active states are gated; work and blocked transitions remain usable", c do
    for {name, type} <- [{"Awaiting approval", "started"}, {"Human Review", "unstarted"}, {"Done", "completed"}, {"In Progress", "completed"}, {"Merging", "started"}] do
      Agent.update(c.api, &%{&1 | state: %{"id" => "state-1", "name" => name, "type" => type}})
      refute call(c, "linear_transition", %{state_id: "state-1"})["success"]
    end

    for {name, type} <- [{"In Progress", "started"}, {"Todo", "unstarted"}, {"Blocked", "started"}, {"Backlog", "backlog"}, {"Canceled", "canceled"}] do
      Agent.update(c.api, &%{&1 | state: %{"id" => "state-1", "name" => name, "type" => type}})
      assert call(c, "linear_transition", %{state_id: "state-1"})["success"]
    end

    refute call(c, "linear_transition", %{state_id: "different-team"})["success"]
    assert transition_count(c) == 5
    assert ReviewRunnerFixture.calls(c.review.state_root) == []
  end

  test "all legacy GraphQL forms and forged typed inputs are rejected before provider access", c do
    for query <- [
          "mutation { alias: issueUpdate(id: \"other\", input: {stateId: \"done\"}) { success } }",
          "mutation($input: IssueUpdateInput!) { issueUpdate(id: \"x\", input: $input) { success } }",
          "query A { viewer { id } } mutation B { issueCreate(input: {}) { success } }"
        ] do
      refute call(c, "linear_graphql", %{query: query, variables: %{}})["success"]
    end

    for {tool, args} <- [
          {"symphony_review", %{operation: "verify"}},
          {"symphony_review", %{operation: "start", run_id: 8}},
          {"linear_transition", %{state_id: "state-1", issue_id: "other"}},
          {"linear_transition", %{state_id: nil}},
          {"linear_comment", %{operation: "create"}},
          {"linear_comment", %{operation: "create", body: []}},
          {"linear_comment", %{operation: "create", body: " "}},
          {"linear_read", %{operation: "comments", cursor: 42}},
          {"linear_attach_pr", %{url: nil}},
          {"linear_attach_pr", %{url: "https://github.com/driver-ai/runtime/pull/1", title: 1}}
        ] do
      refute call(c, tool, args)["success"]
    end

    refute AgentTool.execute("linear_read", %{"operation" => "issue"}, review: %{enabled: true})["success"]
    refute AgentTool.execute("unknown", %{}, c.opts)["success"]
    refute AgentTool.execute("linear_read", "query", c.opts)["success"]
    assert Agent.get(c.api, & &1.calls) == []
  end

  test "issue/comments/team reads and only linked documents remain available", c do
    assert call(c, "linear_read", %{operation: "issue"})["success"]
    assert call(c, "linear_read", %{operation: "comments", cursor: "page-2"})["success"]
    assert call(c, "linear_read", %{operation: "workflow_states"})["success"]
    assert call(c, "linear_read", %{operation: "document", id: "doc-1"})["success"]
    Agent.update(c.api, &put_in(&1.document["issue"], nil))
    refute call(c, "linear_read", %{operation: "document", id: "doc-1"})["success"]
    Agent.update(c.api, &put_in(&1.issue["description"], "Context: https://linear.app/team/document/doc-1"))
    assert call(c, "linear_read", %{operation: "document", id: "doc-1"})["success"]
    refute call(c, "linear_read", %{operation: "document"})["success"]
    assert Enum.any?(Agent.get(c.api, & &1.calls), fn {query, vars} -> query =~ "SymphonyBoundComments" and vars.after == "page-2" end)
  end

  test "comments check membership and ownership before any edit or reply", c do
    assert call(c, "linear_comment", %{operation: "create", body: "workpad"})["success"]
    assert call(c, "linear_comment", %{operation: "update", comment_id: "comment-1", body: "updated"})["success"]
    assert call(c, "linear_comment", %{operation: "reply", parent_id: "comment-1", body: "reply"})["success"]
    Agent.update(c.api, &%{&1 | viewer: nil, author: nil})
    refute call(c, "linear_comment", %{operation: "update", comment_id: "comment-1", body: "overwrite"})["success"]
    Agent.update(c.api, &%{&1 | author: "human", viewer: "agent"})
    refute call(c, "linear_comment", %{operation: "update", comment_id: "comment-1", body: "overwrite"})["success"]
    Agent.update(c.api, &%{&1 | comment_issue: "another-issue"})
    refute call(c, "linear_comment", %{operation: "reply", parent_id: "comment-1", body: "reply"})["success"]
    refute call(c, "linear_comment", %{operation: "update", comment_id: "comment-1", body: "update"})["success"]
    refute call(c, "linear_comment", %{operation: "reply", body: "missing id"})["success"]
    refute call(c, "linear_comment", %{operation: "update", body: "missing id"})["success"]
  end

  test "PR attachment is limited to a valid HTTPS PR in the captured repository", c do
    assert call(c, "linear_attach_pr", %{url: "https://github.com/driver-ai/runtime/pull/5"})["success"]

    for url <- [
          "https://github.com",
          "https://github.com/",
          "https://github.com:bad/driver-ai/runtime/pull/5",
          "https://github.com/other/repo/pull/5",
          "https://evil.test/driver-ai/runtime/pull/5",
          "http://github.com/driver-ai/runtime/pull/5",
          "https://github.com/driver-ai/runtime/pull/0",
          "https://github.com/driver-ai/runtime/pull/abc",
          "https://user@github.com/driver-ai/runtime/pull/5"
        ] do
      refute call(c, "linear_attach_pr", %{url: url})["success"]
    end
  end

  test "a missing repository still permits reporting and blocking the issue", c do
    c = %{c | opts: Keyword.put(c.opts, :repository, nil)}
    assert call(c, "linear_read", %{operation: "issue"})["success"]
    assert call(c, "linear_comment", %{operation: "create", body: "Repository unavailable"})["success"]

    for {tool, args} <- [
          {"symphony_review", %{operation: "start"}},
          {"linear_attach_pr", %{url: "https://github.com/driver-ai/runtime/pull/5"}},
          {"linear_transition", %{state_id: "state-1"}}
        ] do
      response = call(c, tool, args)
      refute response["success"]
      assert response["output"] =~ "review_repository_not_captured"
    end

    Agent.update(c.api, &put_in(&1.state["name"], "Blocked"))
    assert call(c, "linear_transition", %{state_id: "state-1"})["success"]
    assert ReviewRunnerFixture.calls(c.review.state_root) == []
  end

  test "a rejected repository binding cannot start or hand off even with a plausible remote", c do
    c = %{c | opts: Keyword.put(c.opts, :review_repository_error, :review_repository_mismatch)}

    for {tool, args} <- [
          {"symphony_review", %{operation: "start"}},
          {"linear_attach_pr", %{url: "https://github.com/driver-ai/runtime/pull/5"}},
          {"linear_transition", %{state_id: "state-1"}}
        ] do
      response = call(c, tool, args)
      refute response["success"]
      assert response["output"] =~ "review_repository_mismatch"
    end

    assert transition_count(c) == 0
    assert ReviewRunnerFixture.calls(c.review.state_root) == []
  end

  test "provider failures and absent authoritative issues fail without exposing raw errors", c do
    for response <- [
          {:error, {:transport, "secret-provider-output"}},
          {:ok, %{"errors" => ["secret-provider-output"]}},
          {:ok, %{"data" => %{"issue" => nil}}},
          {:ok, %{"data" => %{"issue" => %{"id" => "different-issue"}}}}
        ] do
      opts = Keyword.put(c.opts, :linear_client, fn _, _, _ -> response end)
      result = AgentTool.execute("symphony_review", %{"operation" => "start"}, opts)
      refute result["success"]
      refute result["output"] =~ "secret-provider-output"
      refute AgentTool.execute("linear_read", %{"operation" => "document", "id" => "doc-1"}, opts)["success"]
    end
  end

  defp call(c, tool, args), do: AgentTool.execute(tool, Map.new(args, fn {key, value} -> {to_string(key), value} end), c.opts)
  defp transition_count(c), do: Agent.get(c.api, fn state -> Enum.count(state.calls, fn {query, _} -> query =~ "SymphonyTransition" end) end)

  # The client seam stands for Linear; the actual gate and supervised executable run in every test.
  defp query(api, query, variables) do
    state = Agent.get_and_update(api, &{&1, %{&1 | calls: &1.calls ++ [{query, variables}]}})

    data =
      cond do
        query =~ "SymphonyBoundStates" -> %{"issue" => %{"team" => %{"states" => %{"nodes" => [state.state]}}}}
        query =~ "SymphonyBoundIssue" -> %{"issue" => state.issue}
        query =~ "SymphonyBoundComments" -> %{"issue" => %{"comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}
        query =~ "SymphonyBoundComment" -> %{"viewer" => %{"id" => state.viewer}, "comment" => %{"issue" => %{"id" => state.comment_issue}, "user" => %{"id" => state.author}}}
        query =~ "SymphonyLinkedDocument" -> %{"document" => state.document}
        true -> %{"mutation" => %{"success" => true}}
      end

    {:ok, %{"data" => data}}
  end
end
