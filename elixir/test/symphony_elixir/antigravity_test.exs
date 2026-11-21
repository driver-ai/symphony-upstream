defmodule SymphonyElixir.AntigravityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Antigravity.McpBridge
  alias SymphonyElixir.Config.Schema

  test "antigravity configuration is optional and validates configured values" do
    assert {:ok, settings} = Schema.parse(%{})
    assert is_nil(settings.antigravity)

    assert {:ok, settings} =
             Schema.parse(%{"antigravity" => %{"command" => "agy", "stall_timeout_ms" => 12_345}})

    assert settings.antigravity.command == "agy"
    assert settings.antigravity.stall_timeout_ms == 12_345

    assert {:ok, settings} = Schema.parse(%{"antigravity" => %{"command" => "agy"}})
    assert settings.antigravity.stall_timeout_ms == 300_000

    assert {:error, {:invalid_workflow_config, missing_message}} =
             Schema.parse(%{"antigravity" => %{}})

    assert missing_message =~ "command"

    assert {:ok, settings} =
             Schema.parse(%{"antigravity" => %{"command" => "agy", "stall_timeout_ms" => nil}})

    assert settings.antigravity.stall_timeout_ms == 300_000

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"antigravity" => %{"command" => "  ", "stall_timeout_ms" => 0}})

    assert message =~ "command"
    assert message =~ "stall_timeout_ms"
  end

  test "model labels select the exact harness or return explicit routing errors" do
    config = %{command: "agy"}
    issue = %Issue{labels: []}
    assert {:ok, {:codex, nil}} = AgentRunner.harness_for_issue(issue, config)

    for variant <- ~w(neon argon carbon hydrogen) do
      issue = %Issue{labels: ["model:gemini-4-#{variant}"]}
      expected_model = "runtime/gemini-4-#{variant}"

      assert {:ok, {:antigravity, ^expected_model}} =
               AgentRunner.harness_for_issue(issue, config)
    end

    assert {:error, {:antigravity_not_configured, "model:gemini-4-neon"}} =
             AgentRunner.harness_for_issue(%Issue{labels: ["model:gemini-4-neon"]}, nil)

    assert {:error, {:ambiguous_model_labels, labels}} =
             AgentRunner.harness_for_issue(
               %Issue{labels: ["model:gemini-4-neon", "model:gemini-4-argon"]},
               config
             )

    assert length(labels) == 2

    assert {:ok, {:codex, nil}} =
             AgentRunner.harness_for_issue(%Issue{labels: ["model:foo", "model:bar"]}, nil)
  end

  test "MCP bridge exposes bound tools and delegates calls through the supplied executor" do
    parent = self()

    binding = %{
      tool_specs: [
        %{"name" => "linear_transition", "description" => "guarded", "inputSchema" => %{"type" => "object"}},
        %{"name" => "symphony_review", "description" => "review", "inputSchema" => %{"type" => "object"}}
      ]
    }

    executor = fn name, arguments, received_binding, context ->
      send(parent, {:executed, name, arguments, received_binding, context})
      %{"success" => true, "name" => name}
    end

    for {id, name, arguments} <- [
          {7, "linear_transition", %{"state_id" => "review"}},
          {8, "symphony_review", %{"operation" => "start"}}
        ] do
      response =
        McpBridge.dispatch(
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "method" => "tools/call",
            "params" => %{"name" => name, "arguments" => arguments}
          },
          binding,
          tool_executor: executor,
          context: [session_id: "agy-session"]
        )

      assert get_in(response, ["result", "isError"]) == false
      assert_receive {:executed, ^name, ^arguments, ^binding, [session_id: "agy-session"]}
    end

    assert %{"error" => %{"code" => -32_601}} =
             McpBridge.dispatch(
               %{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/call", "params" => []},
               binding,
               tool_executor: executor
             )

    assert %{"result" => %{"isError" => true}} =
             McpBridge.dispatch(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 10,
                 "method" => "tools/call",
                 "params" => %{"name" => "linear_transition", "arguments" => %{}}
               },
               binding,
               tool_executor: fn _name, _arguments, _binding, _context -> raise "tool failed" end
             )
  end

  test "MCP bridge enforces bearer authentication over loopback HTTP" do
    parent = self()
    binding = %{tool_specs: [%{"name" => "linear_read", "description" => "read", "inputSchema" => %{}}]}

    executor = fn name, arguments, _binding, context ->
      send(parent, {:http_executed, name, arguments, context})
      %{"success" => true}
    end

    assert {:ok, bridge} =
             McpBridge.start(binding,
               tool_executor: executor,
               context: [thread_id: "agy-thread", session_id: "agy-session"]
             )

    on_exit(fn -> McpBridge.stop(bridge) end)
    assert http_post(bridge.url, "wrong", %{"id" => 1, "method" => "tools/list"}) =~ "401 Error"

    assert http_post(bridge.url, bridge.token, %{"id" => 2, "method" => "initialize"}) =~
             "\"protocolVersion\""

    assert http_post(bridge.url, bridge.token, %{
             "id" => 3,
             "method" => "tools/call",
             "params" => %{"name" => "linear_read", "arguments" => %{"operation" => "issue"}}
           }) =~ "200 OK"

    assert_receive {:http_executed, "linear_read", %{"operation" => "issue"}, [thread_id: "agy-thread", session_id: "agy-session"]}
  end

  test "fake agy streams multiple turns, reports usage, isolates secrets, and exposes hook routing" do
    root = Path.join(System.tmp_dir!(), "symphony-antigravity-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    fake = Path.join(root, "fake-agy")
    trace = Path.join(root, "trace")
    File.mkdir_p!(root)

    File.write!(fake, """
    #!/bin/sh
    printf 'ARGS:%s\n' "$*" >> "#{trace}"
    printf 'SECRET:%s\n' "${LINEAR_API_KEY-unset}" >> "#{trace}"
    printf 'MODEL:%s\n' "$SYMPHONY_MODEL_ALIAS" >> "#{trace}"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'INPUT:%s\n' "$line" >> "#{trace}"
      printf 'MCP_MODE:%s\n' "$(stat -c '%a' .agents/mcp_config.json)" >> "#{trace}"
      grep -q 'Bearer ' .agents/mcp_config.json && printf 'MCP_AUTH:present\n' >> "#{trace}"
      printf '{"type":"notification","conversation_id":"conversation-1"}\n'
      printf '{"type":"notification","conversation_id":"conversation-1"}\n'
      printf '{"type":"result","conversation_id":"conversation-1","usage":{"input_tokens":%s}}\n' "$count"
    done
    """)

    File.chmod!(fake, 0o755)
    previous_linear_key = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "must-not-leak")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_key)
      File.rm_rf(root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      antigravity_command: fake,
      antigravity_stall_timeout_ms: 5_000,
      hook_before_run: "printf '%s:%s' \"$SYMPHONY_HARNESS\" \"$SYMPHONY_MODEL_ALIAS\" > hook-env",
      max_turns: 2
    )

    config_path = Path.join([workspace_root, "AGY-1", ".agents", "mcp_config.json"])
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      Jason.encode!(%{
        "mcpServers" => %{
          "custom" => %{"serverUrl" => "http://example.invalid"},
          "symphony" => %{"serverUrl" => "http://127.0.0.1:1/stale"}
        }
      })
    )

    issue = %Issue{
      id: "agy-issue",
      identifier: "AGY-1",
      title: "Antigravity",
      description: "run",
      state: "In Progress",
      labels: ["model:gemini-4-neon"],
      dispatchable: true
    }

    parent = self()

    fetcher = fn [_] ->
      count = Process.get(:agy_fetch_count, 0) + 1
      Process.put(:agy_fetch_count, count)
      state = if count == 1, do: "In Progress", else: "Done"
      {:ok, [%{issue | state: state}]}
    end

    assert :ok = AgentRunner.run(issue, parent, issue_state_fetcher: fetcher)
    contents = File.read!(trace)
    assert contents =~ "--input-format stream-json"
    assert contents =~ "--model runtime/gemini-4-neon"
    assert contents =~ "SECRET:unset"
    assert contents =~ "MODEL:runtime/gemini-4-neon"
    assert contents =~ "MCP_MODE:600"
    assert contents =~ "MCP_AUTH:present"
    assert length(Regex.scan(~r/^INPUT:/m, contents)) == 2
    assert %{"mcpServers" => restored_servers} = config_path |> File.read!() |> Jason.decode!()
    assert Map.has_key?(restored_servers, "custom")
    refute Map.has_key?(restored_servers, "symphony")

    assert File.read!(Path.join([workspace_root, "AGY-1", "hook-env"])) ==
             "antigravity:runtime/gemini-4-neon"

    assert_receive {:codex_worker_update, "agy-issue", %{conversation_id: "conversation-1", usage: %{"input_tokens" => 1}}}
    assert_receive {:codex_worker_update, "agy-issue", %{conversation_id: "conversation-1", usage: %{"input_tokens" => 3}}}
  end

  test "graceful stop terminates fake agy and still runs after_run" do
    root = Path.join(System.tmp_dir!(), "symphony-antigravity-stop-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    fake = Path.join(root, "fake-agy")
    ready = Path.join(root, "ready")
    pid_file = Path.join(root, "pid")
    child_pid_file = Path.join(root, "child-pid")
    after_run = Path.join(root, "after-run")
    File.mkdir_p!(root)

    File.write!(fake, """
    #!/bin/sh
    printf '%s' "$$" > "#{pid_file}"
    while IFS= read -r line; do
      : > "#{ready}"
      sleep 30 &
      printf '%s' "$!" > "#{child_pid_file}"
      wait
    done
    """)

    File.chmod!(fake, 0o755)
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      antigravity_command: fake,
      antigravity_stall_timeout_ms: 60_000,
      hook_after_run: ": > #{after_run}"
    )

    issue = %Issue{
      id: "agy-stop",
      identifier: "AGY-STOP",
      title: "Stop",
      state: "In Progress",
      labels: ["model:gemini-4-neon"]
    }

    task = Task.async(fn -> AgentRunner.run(issue) end)
    assert eventually?(fn -> File.exists?(ready) end)
    assert :ok = AgentRunner.request_stop(task.pid, :issue_inactive)
    assert :ok = Task.await(task, 5_000)
    assert File.exists?(after_run)
    refute File.exists?(Path.join([workspace_root, "AGY-STOP", ".agents", "mcp_config.json"]))
    pid = File.read!(pid_file) |> String.trim()
    child_pid = File.read!(child_pid_file) |> String.trim()

    for stopped_pid <- [pid, child_pid] do
      assert eventually?(fn ->
               {_output, status} = System.cmd("kill", ["-0", stopped_pid], stderr_to_stdout: true)
               status != 0
             end)
    end
  end

  defp http_post(url, token, payload) do
    %URI{host: host, port: port, path: path} = URI.parse(url)
    {:ok, socket} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false])
    body = Jason.encode!(payload)

    request =
      "POST #{path} HTTP/1.1\r\nhost: #{host}\r\nauthorization: Bearer #{token}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

    :ok = :gen_tcp.send(socket, request)
    receive_http(socket, "")
  end

  defp receive_http(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> receive_http(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp eventually?(predicate, attempts \\ 100)
  defp eventually?(_predicate, 0), do: false

  defp eventually?(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(20)
      eventually?(predicate, attempts - 1)
    end
  end
end
