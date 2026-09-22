defmodule SymphonyElixir.ReviewRunnerFixture do
  @moduledoc false

  # This executable stands in for the separately shipped runner and its paid providers.
  def create!(root) do
    File.mkdir_p!(root)
    executable = Path.join(root, "runner.py")
    state_root = Path.join(root, "state")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)
    File.chmod!(state_root, 0o700)

    File.write!(executable, """
    #!/usr/bin/env python3
    import json, os, pathlib, signal, sys, time
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    request = json.load(open(sys.argv[2]))
    root = pathlib.Path(request["state_root"])
    with open(root / "calls", "a") as calls:
        calls.write(json.dumps(request) + "\\n")
    options = json.loads((root / "fixture.json").read_text())
    def wait_for(name):
        deadline = time.monotonic() + 10
        while not (root / name).exists():
            if time.monotonic() > deadline:
                sys.exit(90)
            time.sleep(0.01)
    if options.get("pid_file"):
        (root / "runner-pid").write_text(str(os.getpid()))
    if options.get("cancel_gate") and request["operation"] == "cancel":
        wait_for("cancel")
    if options.get("accept_gate"):
        wait_for("accept")
    common = {"protocol_version": 1, "request_id": request["request_id"],
              "issue_id": request["issue"]["id"], "run_id": request["run_id"] or "run-1"}
    common.update(options.get("envelope", {}))
    def emit(event, **fields):
        print(json.dumps({**common, "event": event, **fields}), flush=True)
    mode = options.get("mode", "complete")
    if mode == "malformed":
        print("not-json", flush=True)
        sys.exit(0)
    if mode == "oversized":
        print("x" * 70000, flush=True)
        sys.exit(0)
    if mode == "unknown_event":
        emit("surprise")
        sys.exit(0)
    if mode == "missing_accept":
        emit("result", status="complete")
        sys.exit(0)
    subject_file = root / (request["issue"]["id"] + "-subject.json")
    subject = {"plan": request["issue"].get("description"), "head": options.get("head", "head-sha")}
    if request["operation"] in ("start", "resume"):
        subject_file.write_text(json.dumps(subject))
    emit("accepted")
    if options.get("duplicate_accept"):
        emit("accepted")
    if options.get("progress"):
        emit("progress")
    if options.get("exit_gate"):
        wait_for("finish")
    if mode == "missing_result":
        sys.exit(0)
    evidence = {"plan_revision": "1", "plan_hash": "plan-hash",
                "repository": request["execution"]["repository"], "base": "base-sha", "head": "head-sha",
                "context_fingerprint": "context-hash", "method_fingerprint": "method-hash",
                "config_fingerprint": "config-hash", "receipts": [{"path": "receipts/reviewer.json", "sha256": "a" * 64}]}
    evidence.update(options.get("evidence", {}))
    # Model the runner's current-plan/current-subject check, outside the runtime's policy.
    status = mode if mode in ("running", "incomplete", "canceled", "unknown") else "complete"
    if request["operation"] == "verify" and (not subject_file.exists() or json.loads(subject_file.read_text()) != subject):
        status = "incomplete"
    common.update(options.get("result_envelope", {}))
    emit("result", status=status, evidence=evidence, reason=options.get("reason", "fixture status"))
    if options.get("duplicate_result"):
        emit("result", status=status, evidence=evidence)
    sys.exit(options.get("exit_status", 0))
    """)

    File.chmod!(executable, 0o700)
    configure!(state_root, %{})
    %{executable: executable, state_root: state_root, workspace: workspace, enabled: true}
  end

  def configure!(root, options),
    do: File.write!(Path.join(root, "fixture.json"), Jason.encode!(options))

  def calls(root) do
    case File.read(Path.join(root, "calls")) do
      {:ok, data} -> data |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  def await_call(root, count, attempts \\ 200)
  def await_call(_root, _count, 0), do: raise("runner did not reach the expected call")

  def await_call(root, count, attempts) do
    if length(calls(root)) >= count do
      :ok
    else
      Process.sleep(10)
      await_call(root, count, attempts - 1)
    end
  end
end
