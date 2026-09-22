defmodule SymphonyElixir.ReviewOperation do
  @moduledoc """
  Runtime-owned boundary for the installed review runner protocol.

  Long-running starts and resumes are owned by this process rather than by the
  Codex tool call. Durable review and accounting records remain runner-owned.
  """

  use GenServer
  require Logger

  @protocol_version 1
  @control_operations ~w(status cancel verify)
  @launch_operations ~w(start resume)
  @operations @launch_operations ++ @control_operations
  @max_output_bytes 65_536

  @type context :: %{
          required(:issue) => map(),
          required(:workspace) => Path.t(),
          required(:repository) => String.t(),
          required(:thread_id) => String.t(),
          required(:session_id) => String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec execute(String.t(), String.t() | nil, context(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute(operation, run_id, context, review, opts \\ [])
      when operation in @operations do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:execute, operation, run_id, context, review}, :infinity)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:execute, operation, run_id, context, review}, from, state)
      when operation in @launch_operations do
    issue_id = get_in(context, [:issue, "id"])

    case Map.get(state, issue_id) || persisted_run(review.state_root, issue_id) do
      %{run_id: known_run_id} = active when is_binary(known_run_id) ->
        {:reply, {:ok, accepted_result(active.request_id, issue_id, known_run_id)}, state}

      %{froms: froms} = active ->
        {:noreply, Map.put(state, issue_id, %{active | froms: [from | froms]})}

      _ ->
        launch_review(operation, run_id, context, review, from, issue_id, state)
    end
  end

  def handle_call({:execute, operation, run_id, context, review}, from, state) do
    issue_id = get_in(context, [:issue, "id"])
    known_run_id = get_in(state, [issue_id, :run_id])
    owner = self()

    case Task.Supervisor.start_child(SymphonyElixir.ReviewTaskSupervisor, fn ->
           result =
             with :ok <- validate_known_run_id(run_id, known_run_id),
                  {:ok, request} <- build_request(operation, run_id || known_run_id, context, review),
                  {:ok, request_path} <- write_request(request, review.state_root) do
               run_control(review.executable, request_path, request)
             end

           send(owner, {:review_control_result, from, operation, issue_id, result})
         end) do
      {:ok, _pid} -> {:noreply, state}
      {:error, reason} -> {:reply, {:error, {:review_control_unavailable, reason}}, state}
    end
  end

  defp launch_review(operation, run_id, context, review, from, issue_id, state) do
    owner = self()
    Logger.info("Launching review operation issue_id=#{issue_id} session_id=#{context.session_id} operation=#{operation}")

    with {:ok, request} <- build_request(operation, run_id, context, review),
         {:ok, request_path} <- write_request(request, review.state_root),
         {:ok, pid} <-
           Task.Supervisor.start_child(SymphonyElixir.ReviewTaskSupervisor, fn ->
             try do
               launch_runner(owner, review.executable, request_path, request)
             after
               File.rm(request_path)
             end
           end) do
      active = %{
        pid: pid,
        monitor: Process.monitor(pid),
        froms: [from],
        request_id: request["request_id"],
        issue_id: issue_id,
        run_id: run_id,
        state_root: review.state_root
      }

      {:noreply, Map.put(state, issue_id, active)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:review_event, issue_id, %{"event" => "accepted"} = event}, state) do
    case Map.get(state, issue_id) do
      %{froms: [_ | _] = froms} = active ->
        case persist_run(active.state_root, issue_id, event) do
          :ok ->
            Logger.info("Review runner accepted issue_id=#{issue_id} run_id=#{event["run_id"]}")
            Enum.each(froms, &GenServer.reply(&1, {:ok, event}))
            {:noreply, Map.put(state, issue_id, %{active | froms: [], run_id: event["run_id"]})}

          {:error, reason} ->
            Enum.each(froms, &GenServer.reply(&1, {:error, {:review_run_persistence_failed, reason}}))
            Process.exit(active.pid, :kill)
            {:noreply, Map.delete(state, issue_id)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:review_event, _issue_id, _event}, state), do: {:noreply, state}

  def handle_info({:review_control_result, from, operation, issue_id, result}, state) do
    GenServer.reply(from, result)
    {:noreply, maybe_reap_canceled_run(operation, issue_id, result, state)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state, fn {_issue_id, active} -> active[:monitor] == monitor end) do
      {issue_id, %{froms: [_ | _] = froms}} ->
        Enum.each(froms, &GenServer.reply(&1, {:error, {:review_runner_ended_before_acceptance, reason}}))
        {:noreply, Map.delete(state, issue_id)}

      {issue_id, _active} ->
        {:noreply, Map.delete(state, issue_id)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp build_request(operation, run_id, context, review) do
    with :ok <- validate_operation_run_id(operation, run_id) do
      {:ok,
       %{
         "protocol_version" => @protocol_version,
         "request_id" => Ecto.UUID.generate(),
         "operation" => operation,
         "run_id" => run_id,
         "issue" => context.issue,
         "execution" => %{
           "workspace" => Path.expand(context.workspace),
           "repository" => context.repository,
           "thread_id" => context.thread_id,
           "session_id" => context.session_id
         },
         "state_root" => review.state_root
       }}
    end
  end

  defp validate_operation_run_id("start", nil), do: :ok
  defp validate_operation_run_id(operation, nil) when operation in ~w(status resume cancel verify), do: :ok
  defp validate_operation_run_id(operation, run_id) when operation in ~w(status resume cancel verify) and is_binary(run_id), do: :ok
  defp validate_operation_run_id(_operation, _run_id), do: {:error, :invalid_review_run_id}

  defp validate_known_run_id(nil, _known_run_id), do: :ok
  defp validate_known_run_id(run_id, nil) when is_binary(run_id), do: :ok
  defp validate_known_run_id(run_id, run_id), do: :ok
  defp validate_known_run_id(_run_id, _known_run_id), do: {:error, :review_run_id_mismatch}

  defp write_request(request, state_root) do
    requests_root = Path.join(state_root, "requests")
    path = Path.join(requests_root, request["request_id"] <> ".json")

    with :ok <- File.mkdir_p(requests_root),
         :ok <- File.write(path, Jason.encode!(request)) do
      {:ok, path}
    end
  end

  defp persisted_run(state_root, issue_id) do
    with {:ok, payload} <- File.read(run_binding_path(state_root, issue_id)),
         {:ok, %{"request_id" => request_id, "run_id" => run_id}} <- Jason.decode(payload),
         true <- is_binary(request_id) and is_binary(run_id) do
      %{request_id: request_id, run_id: run_id}
    else
      _ -> nil
    end
  end

  defp persist_run(state_root, issue_id, event) do
    path = run_binding_path(state_root, issue_id)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(Map.take(event, ["request_id", "run_id"])), [:exclusive]) do
      File.chmod(path, 0o600)
    else
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp run_binding_path(state_root, issue_id) do
    name = :crypto.hash(:sha256, issue_id) |> Base.encode16(case: :lower)
    Path.join([state_root, "runtime-bindings", name <> ".json"])
  end

  defp launch_runner(owner, executable, request_path, request) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          args: [String.to_charlist("--request"), String.to_charlist(request_path)],
          line: 65_536
        ]
      )

    consume_port(port, request, owner, "", 0)
  end

  defp consume_port(port, request, owner, buffer, size) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        payload = buffer <> line
        event = decode_event!(payload, request)
        send(owner, {:review_event, get_in(request, ["issue", "id"]), event})
        consume_port(port, request, owner, "", size + byte_size(line))

      {^port, {:data, {:noeol, chunk}}} when size + byte_size(chunk) <= @max_output_bytes ->
        consume_port(port, request, owner, buffer <> chunk, size + byte_size(chunk))

      {^port, {:data, {:noeol, _chunk}}} ->
        Port.close(port)
        raise ArgumentError, "runner output exceeded the protocol limit"

      {^port, {:exit_status, _status}} ->
        :ok
    end
  end

  defp run_control(executable, request_path, request) do
    try do
      case System.cmd(executable, ["--request", request_path]) do
        {output, 0} ->
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&decode_event!(&1, request))
          |> Enum.reverse()
          |> Enum.find(&(&1["event"] == "result"))
          |> case do
            nil -> {:error, :review_runner_missing_result}
            result -> {:ok, result}
          end

        {_output, status} ->
          {:error, {:review_runner_exit, status}}
      end
    rescue
      error -> {:error, {:invalid_review_runner_output, Exception.message(error)}}
    after
      File.rm(request_path)
    end
  end

  defp maybe_reap_canceled_run("cancel", issue_id, {:ok, %{"status" => "canceled"}}, state) do
    case Map.get(state, issue_id) do
      %{pid: pid, froms: froms, state_root: state_root} when is_pid(pid) ->
        Enum.each(froms, &GenServer.reply(&1, {:error, :review_run_canceled}))
        Process.exit(pid, :kill)
        File.rm(run_binding_path(state_root, issue_id))

      _ -> :ok
    end

    Map.delete(state, issue_id)
  end

  defp maybe_reap_canceled_run(_operation, _issue_id, _result, state), do: state

  defp decode_event!(line, request) do
    event = Jason.decode!(line)

    required = %{
      "protocol_version" => @protocol_version,
      "request_id" => request["request_id"],
      "issue_id" => get_in(request, ["issue", "id"])
    }

    unless Enum.all?(required, fn {key, value} -> event[key] == value end) and
             event["event"] in ~w(accepted progress result) and is_binary(event["run_id"]) and
             valid_result_event?(event) do
      raise ArgumentError, "runner returned a mismatched protocol envelope"
    end

    event
  end

  defp valid_result_event?(%{"event" => "result", "status" => status} = event)
       when status in ~w(running complete incomplete canceled unknown) do
    status == "complete" or
      (is_binary(event["reason"]) and byte_size(event["reason"]) <= 2_000)
  end

  defp valid_result_event?(%{"event" => "result"}), do: false
  defp valid_result_event?(_event), do: true

  defp accepted_result(request_id, issue_id, run_id) do
    %{
      "protocol_version" => @protocol_version,
      "request_id" => request_id,
      "issue_id" => issue_id,
      "run_id" => run_id,
      "event" => "accepted"
    }
  end
end
