defmodule SymphonyElixir.Antigravity.Runner do
  @moduledoc """
  Runs Antigravity CLI in persistent, non-interactive stream-JSON mode.
  """

  require Logger
  alias SymphonyElixir.Antigravity.McpBridge
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config

  @stop_run_message :symphony_stop_run
  @line_bytes 1_048_576

  @type session :: %{
          port: port(),
          bridge: McpBridge.bridge(),
          config_path: Path.t(),
          previous_config: {:ok, binary()} | :missing,
          binding: map(),
          workspace: Path.t(),
          model_alias: String.t()
        }

  @spec start_session(Path.t(), map(), String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, issue, model_alias, opts \\ []) do
    settings = Config.settings!().antigravity
    binding = DynamicTool.bind(workspace, issue)
    context = [issue: issue, workspace: workspace]

    with {:ok, bridge} <- McpBridge.start(binding, Keyword.put(opts, :context, context)),
         {:ok, config_path, previous_config} <- install_mcp_config(workspace, bridge),
         {:ok, port} <- start_port(workspace, settings.command, model_alias, binding) do
      {:ok,
       %{
         port: port,
         bridge: bridge,
         config_path: config_path,
         previous_config: previous_config,
         binding: binding,
         workspace: workspace,
         model_alias: model_alias
       }}
    else
      error -> error
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{port: port} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    send_json(port, %{"type" => "user", "message" => %{"role" => "user", "content" => prompt}})
    await_turn(session, issue, on_message, "", nil, nil)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(session) do
    if is_port(session.port) and not is_nil(Port.info(session.port)), do: Port.close(session.port)
    McpBridge.stop(session.bridge)
    restore_mcp_config(session.config_path, session.previous_config)
    :ok
  end

  defp start_port(workspace, command, model_alias, binding) do
    executable = System.find_executable("bash")

    if executable do
      args = "#{command} --print --input-format stream-json --output-format stream-json --model #{shell_escape(model_alias)} --sandbox --dangerously-skip-permissions"
      secret_env = valid_environment_names(binding.secret_environment_names)

      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-lc", String.to_charlist("exec " <> args)],
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
        Port.close(session.port)
        {:ok, %{result: :stopped, stopped: reason, session_id: conversation_id}}
    after
      Config.settings!().antigravity.stall_timeout_ms -> {:error, :turn_timeout}
    end
  end

  defp handle_line(session, issue, on_message, line, conversation_id, usage) do
    case Jason.decode(line) do
      {:ok, payload} ->
        next_id = payload["conversation_id"] || payload["session_id"] || conversation_id
        next_usage = payload["usage"] || usage
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
    end
  end

  defp terminal?(payload),
    do: payload["type"] in ["result", "turn_completed", "turn/completed"] or payload["done"] == true

  defp emit(on_message, event, payload, conversation_id, usage, model_alias) do
    on_message.(%{
      event: event,
      timestamp: DateTime.utc_now(),
      payload: payload,
      session_id: conversation_id,
      conversation_id: conversation_id,
      usage: usage,
      harness: :antigravity,
      model_alias: model_alias
    })
  end

  defp install_mcp_config(workspace, bridge) do
    path = Path.join([workspace, ".agents", "mcp_config.json"])
    previous = case File.read(path) do {:ok, data} -> {:ok, data}; _ -> :missing end
    File.mkdir_p!(Path.dirname(path))

    existing =
      case previous do
        {:ok, data} ->
          case Jason.decode(data) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        :missing ->
          %{}
      end
    servers = Map.get(existing, "mcpServers", %{})
    config = Map.put(existing, "mcpServers", Map.put(servers, "symphony", %{"serverUrl" => bridge.url, "headers" => %{"Authorization" => "Bearer #{bridge.token}"}}))

    case File.write(path, Jason.encode!(config)) do
      :ok -> {:ok, path, previous}
      error -> error
    end
  end

  defp restore_mcp_config(path, {:ok, data}), do: File.write(path, data)
  defp restore_mcp_config(path, :missing), do: File.rm(path)

  defp valid_environment_names(names),
    do: Enum.filter(names, &(is_binary(&1) and String.match?(&1, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)))

  defp send_json(port, payload), do: Port.command(port, Jason.encode!(payload) <> "\n")
  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
