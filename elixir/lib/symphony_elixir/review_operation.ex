defmodule SymphonyElixir.ReviewOperation do
  @moduledoc """
  Owns installed review processes independently of Codex tool waits.

  The small durable binding is a reconciliation pointer, not a second review
  database: the runner remains authoritative for execution and accounting.
  """
  use GenServer
  require Logger

  @operations ~w(start resume status cancel verify retry)
  @launch_operations ~w(start resume retry)
  @fresh_start_statuses ~w(unstarted complete incomplete canceled)
  @max_event_bytes 65_536
  @control_timeout_ms 5_000

  @type context :: %{
          required(:issue) => map(),
          required(:workspace) => Path.t(),
          required(:repository) => String.t(),
          required(:thread_id) => String.t(),
          required(:session_id) => String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, %{runs: %{}, tasks: %{}}, name: Keyword.get(opts, :name, __MODULE__))

  @spec execute(String.t(), String.t() | nil, context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(operation, run_id, context, review, opts \\ []) when operation in @operations do
    retry = Keyword.get(opts, :retry)

    with :ok <- validate_retry(operation, run_id, retry) do
      retry = if retry, do: %{retry | "attempts" => Enum.sort_by(retry["attempts"], & &1["role"]), "reason" => String.trim(retry["reason"])}
      timeout = if operation in @launch_operations, do: :infinity, else: Keyword.get(opts, :control_timeout_ms, @control_timeout_ms)
      GenServer.call(Keyword.get(opts, :server, __MODULE__), {:execute, operation, run_id, context, review, retry}, timeout)
    end
  catch
    :exit, {:timeout, _call} -> {:error, :review_control_timeout}
    :exit, _reason -> {:error, :review_owner_unavailable}
  end

  @spec validate_retry(String.t(), String.t() | nil, term()) :: :ok | {:error, :invalid_review_retry}
  def validate_retry("retry", run_id, %{"attempts" => attempts, "reason" => reason} = retry)
      when is_binary(run_id) and run_id != "" and is_list(attempts) and is_binary(reason) do
    valid =
      map_size(retry) == 2 and String.trim(reason) != "" and String.length(reason) <= 4096 and valid_retry_attempts?(attempts)

    if valid, do: :ok, else: {:error, :invalid_review_retry}
  end

  def validate_retry(operation, _run_id, nil) when operation != "retry", do: :ok
  def validate_retry(_operation, _run_id, _retry), do: {:error, :invalid_review_retry}

  defp valid_retry_attempts?(attempts) do
    length(attempts) in 1..6 and Enum.all?(attempts, &valid_retry_attempt?/1) and
      length(Enum.uniq_by(attempts, & &1["role"])) == length(attempts)
  end

  defp valid_retry_attempt?(%{"role" => role, "id" => id} = attempt) when is_binary(id),
    do: map_size(attempt) == 2 and role in ~w(general correctness security conventions design tests) and Regex.match?(~r/\A[a-f0-9]{32}\z/, id)

  defp valid_retry_attempt?(_attempt), do: false

  @spec bind_repository(String.t() | nil, String.t() | nil, map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def bind_repository(issue_id, repository, review, opts \\ []) do
    if is_binary(issue_id) and issue_id != "" and is_binary(repository) and repository != "" do
      GenServer.call(Keyword.get(opts, :server, __MODULE__), {:bind_repository, issue_id, repository, review}, @control_timeout_ms)
    else
      {:error, :review_repository_not_captured}
    end
  catch
    :exit, _reason -> {:error, :review_owner_unavailable}
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call({:bind_repository, issue_id, repository, review}, _from, state) do
    result =
      case read_binding(review.state_root, issue_id) do
        {:ok, nil} ->
          case write_binding(review.state_root, issue_id, nil, nil, repository, "unstarted") do
            :ok -> {:ok, repository}
            {:error, _reason} -> {:error, :review_binding_write_failed}
          end

        {:ok, %{"repository" => ^repository}} ->
          {:ok, repository}

        {:ok, _binding} ->
          {:error, :review_repository_mismatch}

        {:error, _reason} = error ->
          error
      end

    {:reply, result, state}
  end

  def handle_call({:execute, operation, run_id, context, review, retry}, from, state) do
    issue_id = context.issue["id"]
    active = Map.get(state.tasks, state.runs[issue_id])
    cancel_pending? = Enum.any?(state.tasks, fn {_ref, task} -> task.context.issue["id"] == issue_id and task.request["operation"] == "cancel" end)

    with {:ok, binding} <- read_binding(review.state_root, issue_id),
         :ok <- validate_binding(binding, run_id, context.repository),
         false <- operation == "retry" and cancel_pending? do
      cond do
        (operation == "retry" and active) && active.request["retry"] != retry ->
          {:reply, {:error, :review_operation_active}, state}

        operation in @launch_operations and active ->
          coalesce_bound(active, context, review, from, state)

        true ->
          start_operation(operation, binding, context, review, retry, from, state)
      end
    else
      true -> {:reply, {:error, :review_cancel_pending}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp coalesce_bound(active, context, review, from, state) do
    if active.review == review and active.context.repository == context.repository and active.context.workspace == context.workspace,
      do: coalesce(active, from, state),
      else: {:reply, {:error, :review_session_binding_mismatch}, state}
  end

  defp coalesce(%{accepted: event}, _from, state) when is_map(event), do: {:reply, {:ok, event}, state}

  defp coalesce(active, from, state),
    do: {:noreply, put_in(state.tasks[active.task.ref].froms, [from | active.froms])}

  defp start_operation(operation, binding, context, review, retry, from, state) do
    with {:ok, request} <- build_request(operation, binding, context, review, retry),
         :ok <- persist_launch(request, review.state_root) do
      owner = self()
      path = Path.join([review.state_root, "requests", Ecto.UUID.generate() <> ".json"])
      runner = fn -> run(owner, request, review, path) end
      task = Task.Supervisor.async_nolink(SymphonyElixir.ReviewTaskSupervisor, runner)
      launch? = request["operation"] in @launch_operations

      active = %{
        task: task,
        request_path: path,
        request: request,
        review: review,
        context: context,
        froms: [from],
        accepted: nil,
        launch?: launch?,
        binding_request_id: binding && binding["request_id"]
      }

      state = put_in(state.tasks[task.ref], active)
      state = if launch?, do: put_in(state.runs[context.issue["id"]], task.ref), else: state
      log_operation(active, "started")
      {:noreply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:review_accepted, pid, event}, state) do
    case Enum.find(state.tasks, fn {_ref, active} -> active.task.pid == pid and active.launch? end) do
      {ref, %{accepted: nil} = active} ->
        case persist_binding(active, event["run_id"], "unknown") do
          :ok ->
            Enum.each(active.froms, &GenServer.reply(&1, {:ok, event}))
            log_operation(active, "accepted")
            {:noreply, put_in(state.tasks[ref], %{active | froms: [], accepted: event})}

          {:error, _reason} ->
            Task.Supervisor.terminate_child(SymphonyElixir.ReviewTaskSupervisor, pid)
            finish(ref, {:error, :review_binding_write_failed}, state)
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref), do: finish(ref, result, state)

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: finish(ref, {:error, :review_runner_unavailable}, state)

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(ref, result, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {active, tasks} ->
        Process.demonitor(ref, [:flush])
        cleanup_request(active.request_path)
        state = %{state | tasks: tasks}
        state = if active.launch?, do: %{state | runs: Map.delete(state.runs, active.context.issue["id"])}, else: state
        result = record_result(active, result)
        Enum.each(active.froms, &GenServer.reply(&1, result))
        log_operation(active, if(match?({:ok, _}, result), do: "finished", else: "failed"))
        {:noreply, reap_canceled(active, result, state)}
    end
  end

  defp record_result(%{launch?: true} = active, {:ok, event} = result) do
    case persist_binding(active, event["run_id"], event["status"]) do
      :ok -> result
      {:error, _reason} -> {:error, :review_binding_write_failed}
    end
  end

  defp record_result(_active, result), do: result

  defp reap_canceled(%{request: %{"operation" => "cancel"}} = control, {:ok, %{"status" => "canceled"} = event}, state) do
    with {:ok, binding} when is_map(binding) <- read_binding(control.review.state_root, control.context.issue["id"]),
         true <- binding["request_id"] == control.binding_request_id and binding["run_id"] == event["run_id"] do
      release_canceled(control, event, state)
    else
      _ -> state
    end
  end

  defp reap_canceled(_active, _result, state), do: state

  defp release_canceled(control, event, state) do
    issue_id = control.context.issue["id"]
    ref = state.runs[issue_id]

    case state.tasks[ref] do
      nil ->
        :ok

      active ->
        Task.Supervisor.terminate_child(SymphonyElixir.ReviewTaskSupervisor, active.task.pid)
        cleanup_request(active.request_path)
    end

    # A confirmed runner cancellation is the authority to release ownership; its
    # accounting records remain untouched. Failed controls never reach this path.
    request = Map.put(control.request, "request_id", control.binding_request_id)
    persist_binding(%{control | request: request}, event["run_id"], "canceled")

    case state.tasks[ref] do
      nil ->
        :ok

      active ->
        Process.demonitor(ref, [:flush])
        Enum.each(active.froms, &GenServer.reply(&1, {:error, :review_run_canceled}))
    end

    %{state | tasks: Map.delete(state.tasks, ref), runs: Map.delete(state.runs, issue_id)}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {_ref, active} ->
      Task.Supervisor.terminate_child(SymphonyElixir.ReviewTaskSupervisor, active.task.pid)
      cleanup_request(active.request_path)
    end)
  end

  defp validate_binding(nil, nil, _repository), do: :ok
  defp validate_binding(nil, _run_id, _repository), do: {:error, :review_run_id_mismatch}

  defp validate_binding(binding, run_id, repository) do
    cond do
      binding["repository"] != repository -> {:error, :review_repository_mismatch}
      run_id != nil and run_id != binding["run_id"] -> {:error, :review_run_id_mismatch}
      true -> :ok
    end
  end

  defp build_request(operation, binding, context, review, retry) do
    with {:ok, resolved_operation, request_id, run_id} <- request_identity(operation, binding),
         effective_retry = if(resolved_operation == "retry", do: retry || binding["retry"]),
         :ok <- validate_retry(resolved_operation, run_id, effective_retry) do
      {:ok,
       %{
         "protocol_version" => 1,
         "request_id" => request_id,
         "operation" => resolved_operation,
         "run_id" => run_id,
         "retry" => effective_retry,
         "issue" => context.issue,
         "execution" => Map.take(context, [:workspace, :repository, :thread_id, :session_id]),
         "state_root" => review.state_root
       }}
    end
  end

  defp request_identity("start", nil), do: {:ok, "start", Ecto.UUID.generate(), nil}
  defp request_identity("start", %{"status" => status}) when status in @fresh_start_statuses, do: request_identity("start", nil)
  defp request_identity(operation, nil) when operation != "start", do: {:error, :review_run_missing}
  defp request_identity(_operation, %{"request_id" => nil}), do: {:error, :review_run_missing}

  defp request_identity("retry", %{"run_id" => run_id}) when is_binary(run_id),
    do: {:ok, "retry", Ecto.UUID.generate(), run_id}

  defp request_identity(operation, %{"retry" => retry} = binding) when operation in ~w(start resume) and is_map(retry),
    do: {:ok, "retry", binding["request_id"], binding["run_id"]}

  defp request_identity(operation, binding) when operation in ~w(start resume),
    do: {:ok, "resume", binding["request_id"], binding["run_id"]}

  defp request_identity(operation, %{"run_id" => run_id}) when is_binary(run_id),
    do: {:ok, operation, Ecto.UUID.generate(), run_id}

  defp request_identity(_operation, _binding), do: {:error, :review_run_requires_reconciliation}

  defp read_binding(root, issue_id) do
    case File.read(binding_path(root, issue_id)) do
      {:error, :enoent} -> {:ok, nil}
      {:ok, payload} -> decode_binding(payload)
      {:error, _reason} -> {:error, :review_binding_unreadable}
    end
  end

  defp decode_binding(payload) do
    case Jason.decode(payload) do
      {:ok, %{"request_id" => nil, "run_id" => nil, "repository" => repository, "status" => "unstarted"} = binding}
      when is_binary(repository) ->
        {:ok, binding}

      {:ok, %{"request_id" => request_id, "run_id" => run_id, "repository" => repository, "status" => status} = binding}
      when is_binary(request_id) and (is_binary(run_id) or is_nil(run_id)) and
             is_binary(repository) and is_binary(status) ->
        {:ok, binding}

      _ ->
        {:error, :review_binding_invalid}
    end
  end

  defp persist_launch(%{"operation" => operation} = request, root) when operation in @launch_operations,
    do: write_binding(root, request["issue"]["id"], request["request_id"], request["run_id"], request["execution"].repository, "unknown", request["retry"])

  defp persist_launch(_request, _root), do: :ok

  defp persist_binding(active, run_id, status),
    do: write_binding(active.review.state_root, active.context.issue["id"], active.request["request_id"], run_id, active.context.repository, status, active.request["retry"])

  defp write_binding(root, issue_id, request_id, run_id, repository, status, retry \\ nil) do
    path = binding_path(root, issue_id)
    atomic_write(path, Jason.encode!(%{request_id: request_id, run_id: run_id, repository: repository, status: status, retry: retry}))
  end

  defp binding_path(root, issue_id),
    do: Path.join([root, "runtime-bindings", Base.encode16(:crypto.hash(:sha256, issue_id), case: :lower) <> ".json"])

  defp atomic_write(path, payload) do
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)), :ok <- File.write(temporary, payload), :ok <- File.chmod(temporary, 0o600) do
      File.rename(temporary, path)
    end
  end

  defp cleanup_request(path) do
    File.rm(path)
    File.rm(path <> ".tmp")
  end

  defp run(owner, request, review, path) do
    # Reconciliation reuses request identity, but concurrent controls must never
    # overwrite a request file that another installed process is still reading.
    with :ok <- atomic_write(path, Jason.encode!(request)) do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(review.executable)},
          [:binary, :exit_status, :use_stdio, args: [~c"--request", String.to_charlist(path)], line: @max_event_bytes]
        )

      try do
        consume(port, request, owner, "", nil, nil)
      after
        if Port.info(port), do: Port.close(port)
      end
    end
  rescue
    _error -> {:error, :invalid_review_runner_output}
  after
    cleanup_request(path)
  end

  defp consume(port, request, owner, buffer, accepted, result) do
    receive do
      {^port, {:data, {ending, chunk}}} ->
        line = buffer <> chunk
        if byte_size(line) > @max_event_bytes, do: raise(ArgumentError, "review event too large")

        if ending == :eol do
          event = decode_event!(line, request, accepted, result)
          {accepted, result} = advance(event, accepted, result, owner)
          consume(port, request, owner, "", accepted, result)
        else
          consume(port, request, owner, line, accepted, result)
        end

      {^port, {:exit_status, 0}} when is_map(result) and buffer == "" ->
        {:ok, result}

      {^port, {:exit_status, _status}} ->
        {:error, :review_runner_incomplete_exit}
    end
  end

  defp advance(%{"event" => "accepted"} = event, _accepted, result, owner) do
    send(owner, {:review_accepted, self(), event})
    {event, result}
  end

  defp advance(%{"event" => "progress"}, accepted, result, _owner), do: {accepted, result}
  defp advance(event, accepted, _result, _owner), do: {accepted, event}

  defp decode_event!(line, request, accepted, result) do
    event = Jason.decode!(line)
    known_id = if accepted, do: accepted["run_id"], else: request["run_id"]

    required = %{"protocol_version" => 1, "request_id" => request["request_id"], "issue_id" => request["issue"]["id"]}

    valid =
      is_map(event) and Map.take(event, Map.keys(required)) == required and
        valid_event_run_id?(event["run_id"], known_id) and is_nil(result) and valid_event?(event, accepted)

    unless valid, do: raise(ArgumentError, "invalid review event")
    event
  end

  defp valid_event_run_id?(run_id, known_id),
    do: is_binary(run_id) and run_id != "" and (is_nil(known_id) or run_id == known_id)

  defp valid_event?(%{"event" => "accepted"}, _accepted), do: true
  defp valid_event?(%{"event" => "progress"}, accepted), do: is_map(accepted)

  defp valid_event?(%{"event" => "result", "status" => status} = event, accepted)
       when status in ~w(running complete incomplete canceled unknown),
       do: is_map(accepted) and (status == "complete" or (is_binary(event["reason"]) and byte_size(event["reason"]) in 1..2_000))

  defp valid_event?(_event, _accepted), do: false

  defp log_operation(active, outcome) do
    Logger.info(
      "Review operation #{outcome} issue_id=#{active.context.issue["id"]} issue_identifier=#{active.context.issue["identifier"]} session_id=#{active.context.session_id} operation=#{active.request["operation"]} request_id=#{active.request["request_id"]}"
    )
  end
end
