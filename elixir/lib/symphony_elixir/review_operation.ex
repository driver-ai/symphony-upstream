defmodule SymphonyElixir.ReviewOperation do
  @moduledoc """
  Runtime-owned boundary for the installed review runner protocol.

  Long-running starts and resumes are owned by this process rather than by the
  Codex tool call. Durable review and accounting records remain runner-owned.
  """

  use GenServer

  @protocol_version 1
  @control_operations ~w(status cancel verify)
  @launch_operations ~w(start resume)
  @operations @launch_operations ++ @control_operations
  @max_output_bytes 65_536

  @type context :: %{
          required(:issue) => map(),
          required(:workspace) => Path.t(),
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

    case Map.get(state, issue_id) do
      %{run_id: known_run_id} = active when is_binary(known_run_id) ->
        {:reply, {:ok, accepted_result(active.request_id, issue_id, known_run_id)}, state}

      _ ->
        launch_review(operation, run_id, context, review, from, issue_id, state)
    end
  end

  def handle_call({:execute, operation, run_id, context, review}, _from, state) do
    issue_id = get_in(context, [:issue, "id"])
    effective_run_id = run_id || get_in(state, [issue_id, :run_id])

    result =
      with {:ok, request} <- build_request(operation, effective_run_id, context, review),
           {:ok, request_path} <- write_request(request, review.state_root) do
        run_control(review.executable, request_path, request)
      end

    next_state = maybe_reap_canceled_run(operation, issue_id, result, state)
    {:reply, result, next_state}
  end

  defp launch_review(operation, run_id, context, review, from, issue_id, state) do
    owner = self()

    with {:ok, request} <- build_request(operation, run_id, context, review),
         {:ok, request_path} <- write_request(request, review.state_root),
         {:ok, pid} <- Task.start(fn -> launch_runner(owner, review.executable, request_path, request) end) do
      active = %{
        pid: pid,
        monitor: Process.monitor(pid),
        from: from,
        request_id: request["request_id"],
        issue_id: issue_id,
        run_id: run_id
      }

      {:noreply, Map.put(state, issue_id, active)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:review_event, issue_id, %{"event" => "accepted"} = event}, state) do
    case Map.get(state, issue_id) do
      %{from: from} = active ->
        GenServer.reply(from, {:ok, event})
        {:noreply, Map.put(state, issue_id, %{active | from: nil, run_id: event["run_id"]})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:review_event, _issue_id, _event}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state, fn {_issue_id, active} -> active[:monitor] == monitor end) do
      {issue_id, %{from: from}} when not is_nil(from) ->
        GenServer.reply(from, {:error, {:review_runner_ended_before_acceptance, reason}})
        {:noreply, Map.delete(state, issue_id)}

      {issue_id, _active} ->
        {:noreply, Map.delete(state, issue_id)}

      nil ->
        {:noreply, state}
    end
  end

  defp build_request(operation, run_id, context, review) do
    with :ok <- validate_operation_run_id(operation, run_id),
         {:ok, repository} <- repository_identity(context.workspace) do
      {:ok,
       %{
         "protocol_version" => @protocol_version,
         "request_id" => Ecto.UUID.generate(),
         "operation" => operation,
         "run_id" => run_id,
         "issue" => context.issue,
         "execution" => %{
           "workspace" => Path.expand(context.workspace),
           "repository" => repository,
           "thread_id" => context.thread_id,
           "session_id" => context.session_id
         },
         "state_root" => review.state_root
       }}
    end
  end

  defp validate_operation_run_id("start", nil), do: :ok
  defp validate_operation_run_id(operation, nil) when operation in ~w(status cancel verify), do: :ok
  defp validate_operation_run_id(operation, run_id) when operation in ~w(status resume cancel verify) and is_binary(run_id), do: :ok
  defp validate_operation_run_id(_operation, _run_id), do: {:error, :invalid_review_run_id}

  defp repository_identity(workspace) do
    case System.cmd("git", ["-C", workspace, "config", "--get", "remote.origin.url"], stderr_to_stdout: true) do
      {remote, 0} -> {:ok, normalize_repository(String.trim(remote))}
      {_output, status} -> {:error, {:review_repository_unavailable, status}}
    end
  end

  defp normalize_repository("git@github.com:" <> path), do: normalize_repository("https://github.com/" <> path)
  defp normalize_repository(remote), do: remote |> String.trim_trailing("/") |> String.trim_trailing(".git")

  defp write_request(request, state_root) do
    requests_root = Path.join(state_root, "requests")
    path = Path.join(requests_root, request["request_id"] <> ".json")

    with :ok <- File.mkdir_p(requests_root),
         :ok <- File.write(path, Jason.encode!(request)) do
      {:ok, path}
    end
  end

  defp launch_runner(owner, executable, request_path, request) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [String.to_charlist("--request"), String.to_charlist(request_path)],
          line: 65_536
        ]
      )

    consume_port(port, request, owner, "", 0)
  end

  defp consume_port(port, request, owner, buffer, size) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        event = decode_event!(line, request)
        send(owner, {:review_event, get_in(request, ["issue", "id"]), event})
        consume_port(port, request, owner, buffer, size + byte_size(line))

      {^port, {:data, {:noeol, chunk}}} when size + byte_size(chunk) <= @max_output_bytes ->
        consume_port(port, request, owner, buffer <> chunk, size + byte_size(chunk))

      {^port, {:exit_status, _status}} ->
        :ok
    end
  end

  defp run_control(executable, request_path, request) do
    case System.cmd(executable, ["--request", request_path], stderr_to_stdout: true) do
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
  end

  defp maybe_reap_canceled_run("cancel", issue_id, {:ok, %{"status" => "canceled"}}, state) do
    case Map.get(state, issue_id) do
      %{pid: pid} when is_pid(pid) -> Process.exit(pid, :kill)
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
