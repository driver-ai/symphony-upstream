defmodule SymphonyElixir.Antigravity.Runner do
  @moduledoc """
  Runs Antigravity CLI in persistent, non-interactive stream-JSON mode.
  """

  require Logger
  alias SymphonyElixir.Antigravity.McpBridge
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{Config, PathSafety}

  @stop_run_message :symphony_stop_run
  @line_bytes 1_048_576

  @type session :: %{
          port: port(),
          os_pid: non_neg_integer() | nil,
          bridge: McpBridge.bridge(),
          config_path: Path.t(),
          previous_config: {:mcp_state, {:ok, binary()} | :missing, term()},
          binding: map(),
          workspace: Path.t(),
          model_alias: String.t(),
          thread_id: String.t(),
          stall_timeout_ms: pos_integer()
        }

  @spec start_session(Path.t(), map(), String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, issue, model_alias, opts \\ []) do
    settings = Config.settings!().antigravity
    binding = DynamicTool.bind(workspace, issue)
    thread_id = "antigravity-" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
    context = [issue: issue, workspace: workspace, thread_id: thread_id, session_id: thread_id]

    bridge_opts = opts |> Keyword.put(:context, context) |> Keyword.put(:require_process_binding, true)

    with {:ok, bridge} <- McpBridge.start(binding, bridge_opts) do
      start_with_bridge(bridge, workspace, settings.command, model_alias, binding, thread_id)
    end
  end

  defp start_with_bridge(bridge, workspace, command, model_alias, binding, thread_id) do
    case install_mcp_config(workspace, bridge) do
      {:ok, config_path, previous_config} ->
        start_with_config(bridge, config_path, previous_config, workspace, command, model_alias, binding, thread_id)

      error ->
        McpBridge.stop(bridge)
        error
    end
  end

  defp start_with_config(bridge, config_path, previous_config, workspace, command, model_alias, binding, thread_id) do
    case start_port(workspace, command, model_alias, binding) do
      {:ok, port} ->
        os_pid = port_os_pid(port)
        :ok = McpBridge.authorize_process(bridge, os_pid)

        {:ok,
         %{
           port: port,
           os_pid: os_pid,
           bridge: bridge,
           config_path: config_path,
           previous_config: previous_config,
           binding: binding,
           workspace: workspace,
           model_alias: model_alias,
           thread_id: thread_id,
           stall_timeout_ms: Config.settings!().antigravity.stall_timeout_ms
         }}

      error ->
        restore_mcp_config(config_path, previous_config)
        McpBridge.stop(bridge)
        error
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{port: port} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    turn_id = :erlang.unique_integer([:positive]) |> Integer.to_string()
    session_id = "#{session.thread_id}-#{turn_id}"
    emit(on_message, :session_started, %{}, session_id, %{}, session.model_alias)
    send_json(port, %{"event" => "user", "message" => %{"content" => prompt}})
    await_turn(session, issue, on_message, "", session_id, nil)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(session) do
    terminate_port(session)
    McpBridge.stop(session.bridge)
    restore_mcp_config(session.config_path, session.previous_config)
    :ok
  end

  defp start_port(workspace, command, model_alias, binding) do
    executable = System.find_executable("bash")

    if executable do
      secret_env = valid_environment_names(binding.secret_environment_names)
      unset = if secret_env == [], do: "", else: "unset #{Enum.join(secret_env, " ")} && "
      args = "#{unset}exec #{command} --input-format stream-json --output-format stream-json --model #{shell_escape(model_alias)} --sandbox --dangerously-skip-permissions"

      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-lc", String.to_charlist(args)],
          cd: String.to_charlist(workspace),
          env:
            Enum.map(secret_env, &{String.to_charlist(&1), false}) ++
              [{~c"SYMPHONY_HARNESS", ~c"antigravity"}, {~c"SYMPHONY_MODEL_ALIAS", String.to_charlist(model_alias)}],
          line: @line_bytes
        ])

      {:ok, port}
    else
      {:error, :bash_not_found}
    end
  end

  defp await_turn(session, issue, on_message, pending, conversation_id, usage) do
    receive do
      {port, {:data, {:eol, chunk}}} when port == session.port ->
        handle_line(session, issue, on_message, pending <> to_string(chunk), conversation_id, usage)

      {port, {:data, {:noeol, chunk}}} when port == session.port ->
        await_turn(session, issue, on_message, pending <> to_string(chunk), conversation_id, usage)

      {port, {:exit_status, status}} when port == session.port ->
        {:error, {:port_exit, status}}

      {@stop_run_message, reason} ->
        terminate_port(session)
        {:ok, %{result: :stopped, stopped: reason, session_id: conversation_id}}
    after
      session.stall_timeout_ms ->
        terminate_port(session)
        {:error, :turn_timeout}
    end
  end

  defp handle_line(session, issue, on_message, line, conversation_id, usage) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        next_id = extract_conversation_id(payload, conversation_id)
        next_usage = update_usage(session.thread_id, extract_usage(payload), usage)
        event = if terminal?(payload), do: :turn_completed, else: :notification
        emit(on_message, event, payload, next_id, next_usage, session.model_alias)

        if terminal?(payload) do
          {:ok, %{result: payload, session_id: next_id, conversation_id: next_id, usage: next_usage}}
        else
          await_turn(session, issue, on_message, "", next_id, next_usage)
        end

      {:error, _} ->
        Logger.debug("Ignoring non-JSON Antigravity output: #{inspect(String.slice(line, 0, 1_000))}")
        await_turn(session, issue, on_message, "", conversation_id, usage)

      {:ok, _} ->
        Logger.debug("Ignoring non-object Antigravity JSON output")
        await_turn(session, issue, on_message, "", conversation_id, usage)
    end
  end

  defp extract_conversation_id(payload, fallback) do
    payload["conversation_id"] ||
      payload["session_id"] ||
      nested_field(payload, "result", "conversation_id") ||
      nested_field(payload, "step_update", "conversation_id") ||
      fallback
  end

  defp extract_usage(payload) do
    payload["usage"] || nested_field(payload, "result", "usage")
  end

  defp nested_field(payload, section, key) do
    case Map.get(payload, section) do
      %{} = nested -> Map.get(nested, key)
      _ -> nil
    end
  end

  defp terminal?(payload) do
    payload["event"] == "result" or
      payload["type"] in ["result", "turn_completed", "turn/completed"] or
      payload["done"] == true
  end

  defp emit(on_message, event, payload, conversation_id, usage, model_alias) do
    token_payload = Map.put(payload, "tokenUsage", %{"total" => usage})

    on_message.(%{
      event: event,
      timestamp: DateTime.utc_now(),
      payload: token_payload,
      session_id: conversation_id,
      conversation_id: conversation_id,
      usage: usage,
      harness: :antigravity,
      model_alias: model_alias
    })
  end

  defp install_mcp_config(workspace, bridge) do
    path = Path.join([workspace, ".agents", "mcp_config.json"])

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         :ok <- ensure_safe_config_parent(path, canonical_workspace),
         :ok <- refuse_symlink(path) do
      write_mcp_config(path, bridge)
    end
  end

  defp write_mcp_config(path, bridge) do
    previous = read_previous_config(path)
    File.mkdir_p!(Path.dirname(path))
    parent_identity = file_identity!(Path.dirname(path))
    existing = decode_previous_config(previous)
    servers = normalize_mcp_servers(existing)
    server = %{"serverUrl" => bridge.url, "headers" => %{"Authorization" => "Bearer #{bridge.token}"}}
    config = Map.put(existing, "mcpServers", Map.put(servers, "symphony", server))

    temporary = temporary_config_path(path)

    with :ok <- write_private_file(temporary, Jason.encode!(config)),
         :ok <- File.rename(temporary, path) do
      {:ok, path, {:mcp_state, previous, parent_identity}}
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  defp read_previous_config(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, remove_stale_symphony_server(data)}
      _ -> :missing
    end
  end

  defp remove_stale_symphony_server(data) do
    with {:ok, config} when is_map(config) <- Jason.decode(data),
         servers when is_map(servers) <- config["mcpServers"],
         true <- Map.has_key?(servers, "symphony") do
      config |> Map.put("mcpServers", Map.delete(servers, "symphony")) |> Jason.encode!()
    else
      _ -> data
    end
  end

  defp temporary_config_path(path) do
    suffix = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    Path.join(Path.dirname(path), ".symphony-mcp-#{suffix}")
  end

  defp write_private_file(path, contents) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          with :ok <- File.chmod(path, 0o600), do: IO.binwrite(io, contents)
        after
          File.close(io)
        end

      error ->
        error
    end
  end

  defp decode_previous_config({:ok, data}) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_previous_config(:missing), do: %{}

  defp normalize_mcp_servers(existing) do
    case Map.get(existing, "mcpServers", %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp restore_mcp_config(path, {:mcp_state, previous, expected_parent}) do
    workspace = path |> Path.dirname() |> Path.dirname()

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         :ok <- ensure_safe_config_parent(path, canonical_workspace),
         {:ok, current_parent} <- file_identity(Path.dirname(path)),
         true <- current_parent == expected_parent,
         :ok <- refuse_symlink(path) do
      do_restore_mcp_config(path, previous)
    else
      false -> {:error, :unsafe_mcp_config_path}
      error -> error
    end
  end

  defp do_restore_mcp_config(path, {:ok, data}) do
    temporary = temporary_config_path(path)

    with :ok <- write_private_file(temporary, data),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  defp do_restore_mcp_config(path, :missing), do: File.rm(path)

  defp ensure_safe_config_parent(path, canonical_workspace) do
    parent = Path.dirname(path)

    case File.lstat(parent) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :unsafe_mcp_config_path}
      _ -> ensure_under_workspace(parent, canonical_workspace)
    end
  end

  defp ensure_under_workspace(parent, canonical_workspace) do
    existing = if File.exists?(parent), do: parent, else: Path.dirname(parent)

    case PathSafety.canonicalize(existing) do
      {:ok, canonical} ->
        if canonical == canonical_workspace or String.starts_with?(canonical, canonical_workspace <> "/"),
          do: :ok,
          else: {:error, :unsafe_mcp_config_path}

      _ ->
        {:error, :unsafe_mcp_config_path}
    end
  end

  defp refuse_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :unsafe_mcp_config_path}
      _ -> :ok
    end
  end

  defp file_identity!(path) do
    stat = File.stat!(path)
    {stat.major_device, stat.inode}
  end

  defp file_identity(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, {stat.major_device, stat.inode}}
      _ -> {:error, :unsafe_mcp_config_path}
    end
  end

  defp update_usage(thread_id, usage, _current) when is_map(usage), do: cumulative_usage(thread_id, usage)
  defp update_usage(thread_id, _usage, current), do: current || Process.get({:antigravity_usage, thread_id}, %{})

  defp cumulative_usage(thread_id, usage) when is_map(usage) do
    current = Process.get({:antigravity_usage, thread_id}, %{})

    total =
      Map.merge(current, usage, fn _key, left, right ->
        if is_number(left) and is_number(right), do: left + right, else: right
      end)

    Process.put({:antigravity_usage, thread_id}, total)
    total
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp terminate_port(%{port: port, os_pid: os_pid}) do
    if port in Port.list() do
      do_terminate_port(port, os_pid)
    else
      :ok
    end
  end

  defp do_terminate_port(port, os_pid) do
    signal_process_tree(os_pid, "-TERM")

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      2_000 ->
        signal_process_tree(os_pid, "-KILL")
        if port in Port.list(), do: Port.close(port)
    end
  end

  defp signal_process_tree(os_pid, signal) when is_integer(os_pid) do
    descendants = process_descendants(os_pid)

    Enum.each(descendants ++ [os_pid], fn pid ->
      System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)
    end)
  end

  defp signal_process_tree(_os_pid, _signal), do: :ok

  defp process_descendants(root_pid) do
    case System.cmd("ps", ["-eo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        children =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, &add_process_relationship/2)

        collect_descendants([root_pid], children, [])

      _ ->
        []
    end
  end

  defp add_process_relationship(line, acc) do
    case line |> String.split() |> Enum.map(&Integer.parse/1) do
      [{pid, ""}, {parent, ""}] -> Map.update(acc, parent, [pid], &[pid | &1])
      _ -> acc
    end
  end

  defp collect_descendants([], _children, acc), do: acc

  defp collect_descendants([pid | pending], children, acc) do
    direct = Map.get(children, pid, [])
    collect_descendants(direct ++ pending, children, direct ++ acc)
  end

  defp valid_environment_names(names),
    do: Enum.filter(names, &(is_binary(&1) and String.match?(&1, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)))

  defp send_json(port, payload), do: Port.command(port, Jason.encode!(payload) <> "\n")
  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
