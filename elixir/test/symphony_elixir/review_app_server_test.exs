defmodule SymphonyElixir.ReviewAppServerTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ReviewRunnerFixture

  defmodule LinearEndpoint do
    @behaviour Plug

    @impl true
    def init(options), do: options

    @impl true
    def call(conn, %{owner: owner, issue: issue}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(owner, {:linear_request, request})

      data =
        cond do
          request["query"] =~ "SymphonyBoundStates" ->
            %{issue: %{id: issue.id, team: %{states: %{nodes: [%{id: "review-state", name: "In Review", type: "started"}]}}}}

          request["query"] =~ "SymphonyTransition" ->
            %{issueUpdate: %{success: true}}

          true ->
            %{issue: Map.take(issue, [:id, :identifier, :description])}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{data: data}))
    end
  end

  test "the default app-server executor binds real session context through review and handoff" do
    parent = System.get_env("REVIEW_TEST_TRUSTED_ROOT", File.cwd!())
    root = Path.join(parent, ".review-app-server-#{System.unique_integer([:positive])}")
    review = ReviewRunnerFixture.create!(root)
    workspace = Path.join(review.workspace, "SYM-WIRING")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    {_, 0} = System.cmd("git", ["init", "-q", workspace])
    {_, 0} = System.cmd("git", ["-C", workspace, "remote", "add", "origin", "https://github.com/driver-ai/runtime.git"])

    issue = %Issue{
      id: "issue-wiring-#{System.unique_integer([:positive])}",
      identifier: "SYM-WIRING",
      title: "Review tool wiring",
      description: "current plan",
      state: "In Progress"
    }

    plug = {LinearEndpoint, %{owner: self(), issue: issue}}
    endpoint = start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(endpoint)
    trace = Path.join(root, "codex.jsonl")
    codex = Path.join(root, "fake-codex")

    File.write!(codex, """
    #!/usr/bin/env python3
    import json, sys
    def emit(message):
        print(json.dumps(message), flush=True)
    def tool_call(call_id, tool, arguments):
        emit({"id": call_id, "method": "item/tool/call", "params": {
            "tool": tool, "arguments": arguments,
            "threadId": "thread-real", "turnId": "turn-real"}})
    for line in sys.stdin:
        message = json.loads(line)
        with open(#{Jason.encode!(trace)}, "a") as trace:
            trace.write(json.dumps(message) + "\\n")
        method = message.get("method")
        if method == "initialize":
            emit({"id": message["id"], "result": {}})
        elif method == "thread/start":
            emit({"id": message["id"], "result": {"thread": {"id": "thread-real"}}})
        elif method == "turn/start":
            emit({"id": message["id"], "result": {"turn": {"id": "turn-real"}}})
            tool_call(101, "symphony_review", {"operation": "start"})
        elif message.get("id") == 101:
            tool_call(102, "linear_transition", {"state_id": "review-state"})
        elif message.get("id") == 102:
            emit({"method": "turn/completed"})
            break
    """)

    File.chmod!(codex, 0o700)
    workflow = Workflow.workflow_file_path()

    write_workflow_file!(workflow,
      workspace_root: review.workspace,
      tracker_endpoint: "http://127.0.0.1:#{port}/graphql",
      codex_command: "#{codex} app-server"
    )

    enabled = "review:\n  enabled: true\n  executable: #{Jason.encode!(review.executable)}\n  state_root: #{Jason.encode!(review.state_root)}\n"
    File.write!(workflow, String.replace(File.read!(workflow), "---\n", "---\n" <> enabled, global: false))
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{session_id: "thread-real-turn-real"}} = AppServer.run(workspace, "Perform the review", issue)
    messages = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    for id <- [101, 102] do
      response = Enum.find(messages, &(&1["id"] == id))
      assert response["result"]["success"], inspect(response)
    end

    [start, verify] = ReviewRunnerFixture.calls(review.state_root)
    assert start["operation"] == "start"
    assert verify["operation"] == "verify"

    for request <- [start, verify] do
      assert request["execution"] == %{
               "workspace" => workspace,
               "repository" => "driver-ai/runtime",
               "thread_id" => "thread-real",
               "session_id" => "thread-real-turn-real"
             }

      assert request["issue"]["id"] == issue.id
    end

    issue_id = issue.id
    assert_received {:linear_request, %{"variables" => %{"id" => ^issue_id, "stateId" => "review-state"}}}
  end
end
