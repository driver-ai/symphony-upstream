defmodule SymphonyElixir.ReviewOperationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ReviewOperation, ReviewRunnerFixture}

  setup do
    root = Path.join(System.tmp_dir!(), "review-operation-#{System.unique_integer([:positive])}")
    review = ReviewRunnerFixture.create!(root)
    server = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
    start_supervised!({ReviewOperation, name: server})
    on_exit(fn -> File.rm_rf(root) end)

    context = %{
      issue: %{"id" => "issue-1", "identifier" => "SYM-1", "description" => "current plan"},
      workspace: review.workspace,
      repository: "driver-ai/runtime",
      thread_id: "thread-1",
      session_id: "session-1"
    }

    %{review: review, server: server, context: context}
  end

  test "concurrent starts coalesce before acceptance and duplicate acceptance stays healthy", c do
    ReviewRunnerFixture.configure!(c.review.state_root, %{
      accept_gate: true,
      exit_gate: true,
      duplicate_accept: true
    })

    first = Task.async(fn -> execute(c, "start") end)
    ReviewRunnerFixture.await_call(c.review.state_root, 1)
    second = Task.async(fn -> execute(c, "start") end)
    File.write!(Path.join(c.review.state_root, "accept"), "")
    assert {:ok, %{"run_id" => "run-1"}} = Task.await(first)
    assert {:ok, %{"run_id" => "run-1"}} = Task.await(second)
    assert {:ok, %{"run_id" => "run-1"}} = execute(c, "start")
    assert length(ReviewRunnerFixture.calls(c.review.state_root)) == 1
    File.write!(Path.join(c.review.state_root, "finish"), "")
  end

  test "resume contacts the runner with its durable binding after the owner restarts", c do
    assert {:ok, _} = execute(c, "start")
    stop_supervised!(ReviewOperation)
    start_supervised!({ReviewOperation, name: c.server})
    assert {:ok, %{"run_id" => "run-1"}} = execute(c, "resume")
    ReviewRunnerFixture.await_call(c.review.state_root, 2)
    [start, resume] = ReviewRunnerFixture.calls(c.review.state_root)
    assert resume["operation"] == "resume"
    assert resume["run_id"] == "run-1"
    assert resume["request_id"] == start["request_id"]
  end

  test "control calls reject a different or unbound worker run ID", c do
    assert {:error, _} = execute(c, "cancel", "another-run")
    assert ReviewRunnerFixture.calls(c.review.state_root) == []
    assert {:ok, _} = execute(c, "start")
    assert {:error, _} = execute(c, "cancel", "another-run")
    assert {:ok, %{"status" => "complete"}} = execute(c, "verify")
    [_, verify] = ReviewRunnerFixture.calls(c.review.state_root)
    assert verify["run_id"] == "run-1"
  end

  test "control result requires matching ordered events and a successful exit", c do
    assert {:ok, _} = execute(c, "start")

    for options <- [
          %{mode: "malformed"},
          %{mode: "unknown_event"},
          %{duplicate_result: true},
          %{mode: "unknown", reason: ""},
          %{mode: "oversized"},
          %{mode: "missing_accept"},
          %{mode: "missing_result"},
          %{envelope: %{protocol_version: 2}},
          %{envelope: %{issue_id: "other"}},
          %{exit_status: 2}
        ] do
      ReviewRunnerFixture.configure!(c.review.state_root, options)
      assert {:error, _} = execute(c, "verify")
    end

    ReviewRunnerFixture.configure!(c.review.state_root, %{})
    assert {:ok, %{"status" => "complete"}} = execute(c, "verify")
  end

  test "a slow control call does not hold the owner or another issue", c do
    assert {:ok, _} = execute(c, "start")
    ReviewRunnerFixture.configure!(c.review.state_root, %{exit_gate: true})
    control = Task.async(fn -> execute(c, "verify") end)
    ReviewRunnerFixture.await_call(c.review.state_root, 2)
    other = %{c.context | issue: Map.put(c.context.issue, "id", "issue-2")}
    assert {:ok, _} = ReviewOperation.execute("start", nil, other, c.review, server: c.server)
    File.write!(Path.join(c.review.state_root, "finish"), "")
    assert {:ok, _} = Task.await(control)
  end

  test "unknown cancellation retains ownership; confirmed cancellation permits a new start", c do
    ReviewRunnerFixture.configure!(c.review.state_root, %{exit_gate: true})
    assert {:ok, _} = execute(c, "start")
    ReviewRunnerFixture.configure!(c.review.state_root, %{mode: "unknown"})
    assert {:ok, %{"status" => "unknown"}} = execute(c, "cancel")
    assert {:ok, _} = execute(c, "start")
    assert length(ReviewRunnerFixture.calls(c.review.state_root)) == 2
    ReviewRunnerFixture.configure!(c.review.state_root, %{mode: "canceled"})
    assert {:ok, %{"status" => "canceled"}} = execute(c, "cancel")
    ReviewRunnerFixture.configure!(c.review.state_root, %{})
    assert {:ok, _} = execute(c, "start")
    ReviewRunnerFixture.await_call(c.review.state_root, 4)
  end

  test "an unavailable owner returns a bounded failure", c do
    stop_supervised!(ReviewOperation)
    assert {:error, _} = execute(c, "verify")
  end

  test "owner failure before acceptance retains a recoverable request and replies to callers", c do
    assert {:error, {:already_started, _pid}} = ReviewOperation.start_link()
    send(c.server, :late_message)
    send(c.server, {make_ref(), {:error, :late_result}})
    ReviewRunnerFixture.configure!(c.review.state_root, %{accept_gate: true})
    before = Task.Supervisor.children(SymphonyElixir.ReviewTaskSupervisor)
    caller = Task.async(fn -> execute(c, "start") end)
    ReviewRunnerFixture.await_call(c.review.state_root, 1)
    [runner_task] = Task.Supervisor.children(SymphonyElixir.ReviewTaskSupervisor) -- before
    :ok = Task.Supervisor.terminate_child(SymphonyElixir.ReviewTaskSupervisor, runner_task)
    assert {:error, :review_runner_unavailable} = Task.await(caller)
    assert File.ls!(Path.join(c.review.state_root, "requests")) == []
    assert {:error, :review_run_requires_reconciliation} = execute(c, "status")
    ReviewRunnerFixture.configure!(c.review.state_root, %{progress: true})
    assert {:ok, _} = execute(c, "resume")
    [start, resume] = ReviewRunnerFixture.calls(c.review.state_root)
    assert resume["request_id"] == start["request_id"]
    assert resume["run_id"] == nil
    assert {:ok, _} = execute(c, "verify")
  end

  test "corrupt and unreadable bindings never trigger a blind new launch", c do
    assert {:ok, _} = execute(c, "start")
    stop_supervised!(ReviewOperation)
    start_supervised!({ReviewOperation, name: c.server})
    [binding] = Path.wildcard(Path.join(c.review.state_root, "runtime-bindings/*.json"))
    original = File.read!(binding)
    File.write!(binding, "corrupt")
    assert {:error, :review_binding_invalid} = execute(c, "start")
    File.rm!(binding)
    File.mkdir!(binding)
    assert {:error, :review_binding_unreadable} = execute(c, "resume")
    File.rmdir!(binding)
    File.write!(binding, original)
    other = %{c.context | repository: "other/repository"}
    assert {:error, :review_repository_mismatch} = ReviewOperation.execute("resume", nil, other, c.review, server: c.server)
    assert length(ReviewRunnerFixture.calls(c.review.state_root)) == 1
  end

  test "acceptance persistence failure rejects every waiter without killing the owner", c do
    ReviewRunnerFixture.configure!(c.review.state_root, %{accept_gate: true})
    caller = Task.async(fn -> execute(c, "start") end)
    ReviewRunnerFixture.await_call(c.review.state_root, 1)
    bindings = Path.join(c.review.state_root, "runtime-bindings")
    File.rm_rf!(bindings)
    File.write!(bindings, "blocked storage")
    File.write!(Path.join(c.review.state_root, "accept"), "")
    assert {:error, :review_binding_write_failed} = Task.await(caller)
    assert {:error, :review_binding_unreadable} = execute(c, "status")
  end

  test "lost completion storage and changed session config cannot create a completed run", c do
    ReviewRunnerFixture.configure!(c.review.state_root, %{exit_gate: true})
    before = Task.Supervisor.children(SymphonyElixir.ReviewTaskSupervisor)
    assert {:ok, _} = execute(c, "start")
    [runner_task] = Task.Supervisor.children(SymphonyElixir.ReviewTaskSupervisor) -- before
    monitor = Process.monitor(runner_task)
    changed_review = %{c.review | executable: c.review.executable <> "-changed"}
    response = ReviewOperation.execute("start", nil, c.context, changed_review, server: c.server)
    assert {:error, :review_session_binding_mismatch} = response
    bindings = Path.join(c.review.state_root, "runtime-bindings")
    File.rm_rf!(bindings)
    File.write!(bindings, "blocked storage")

    logs =
      capture_log(fn ->
        File.write!(Path.join(c.review.state_root, "finish"), "")
        assert_receive {:DOWN, ^monitor, :process, ^runner_task, _}, 2_000
        assert {:error, :review_binding_unreadable} = execute(c, "verify")
      end)

    assert logs =~ "Review operation failed"
    assert logs =~ "issue_identifier=SYM-1"
  end

  test "cancel reconciles a run after owner restart and retains its records", c do
    ReviewRunnerFixture.configure!(c.review.state_root, %{exit_gate: true})
    assert {:ok, _} = execute(c, "start")
    stop_supervised!(ReviewOperation)
    start_supervised!({ReviewOperation, name: c.server})
    ReviewRunnerFixture.configure!(c.review.state_root, %{mode: "canceled"})
    assert {:ok, %{"status" => "canceled"}} = execute(c, "cancel")
    assert Path.wildcard(Path.join(c.review.state_root, "runtime-bindings/*.json")) != []
    ReviewRunnerFixture.configure!(c.review.state_root, %{})
    assert {:ok, _} = execute(c, "start")
    [first, cancel, next] = ReviewRunnerFixture.calls(c.review.state_root)
    assert cancel["run_id"] == "run-1"
    assert next["request_id"] != first["request_id"]
    assert next["operation"] == "start"
  end

  test "a late cancel for an older run cannot release a newer owned run", c do
    assert {:ok, _} = execute(c, "start")
    assert {:ok, _} = execute(c, "verify")
    ReviewRunnerFixture.configure!(c.review.state_root, %{cancel_gate: true, mode: "canceled"})
    cancel = Task.async(fn -> execute(c, "cancel") end)
    ReviewRunnerFixture.await_call(c.review.state_root, 3)
    ReviewRunnerFixture.configure!(c.review.state_root, %{envelope: %{run_id: "run-2"}, exit_gate: true})
    assert {:ok, %{"run_id" => "run-2"}} = execute(c, "start")
    File.write!(Path.join(c.review.state_root, "cancel"), "")
    assert {:ok, %{"run_id" => "run-1", "status" => "canceled"}} = Task.await(cancel)
    assert {:ok, %{"run_id" => "run-2"}} = execute(c, "start")
    assert length(ReviewRunnerFixture.calls(c.review.state_root)) == 4
    File.write!(Path.join(c.review.state_root, "finish"), "")
  end

  defp execute(c, operation, run_id \\ nil),
    do: ReviewOperation.execute(operation, run_id, c.context, c.review, server: c.server)
end
