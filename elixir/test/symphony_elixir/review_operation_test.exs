defmodule SymphonyElixir.ReviewOperationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ReviewOperation

  test "the runtime owns a launched runner after acceptance and coalesces duplicate starts" do
    root = Path.join(System.tmp_dir!(), "review-operation-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    state_root = Path.join(root, "state")
    executable = Path.join(root, "runner.py")
    server = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(workspace)
      File.mkdir_p!(state_root)
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "remote", "add", "origin", "https://github.com/driver-ai/runtime.git"])

      File.write!(executable, """
      #!/usr/bin/env python3
      import json, sys, time
      request = json.load(open(sys.argv[2]))
      with open(request["state_root"] + "/invocations", "a") as calls:
          calls.write(request["operation"] + "\\n")
      common = {"protocol_version": 1, "request_id": request["request_id"], "issue_id": request["issue"]["id"], "run_id": "run-1"}
      print(json.dumps({**common, "event": "accepted"}), flush=True)
      time.sleep(0.1)
      print(json.dumps({**common, "event": "result", "status": "complete"}), flush=True)
      """)

      File.chmod!(executable, 0o700)
      start_supervised!({ReviewOperation, name: server})

      context = %{
        issue: %{"id" => "issue-1", "identifier" => "SYM-1", "description" => "plan"},
        workspace: workspace,
        repository: "driver-ai/runtime",
        thread_id: "thread-1",
        session_id: "session-1"
      }

      review = %{executable: executable, state_root: state_root}
      assert {:ok, %{"event" => "accepted", "run_id" => "run-1"}} = ReviewOperation.execute("start", nil, context, review, server: server)
      assert {:ok, %{"event" => "accepted", "run_id" => "run-1"}} = ReviewOperation.execute("start", nil, context, review, server: server)
      assert File.read!(Path.join(state_root, "invocations")) == "start\n"
    after
      File.rm_rf(root)
    end
  end
end
