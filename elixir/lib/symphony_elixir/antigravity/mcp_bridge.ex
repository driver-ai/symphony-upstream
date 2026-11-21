defmodule SymphonyElixir.Antigravity.McpBridge do
  @moduledoc false

  alias SymphonyElixir.Codex.DynamicTool

  @type bridge :: %{listener: port(), acceptor: pid(), url: String.t(), token: String.t()}

  @spec start(map(), keyword()) :: {:ok, bridge()} | {:error, term()}
  def start(binding, opts \\ []) do
    executor = Keyword.get(opts, :tool_executor, &DynamicTool.execute/4)
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    with {:ok, listener} <-
           :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]),
         {:ok, {_address, port}} <- :inet.sockname(listener) do
      owner = self()
      acceptor = spawn_link(fn -> accept_loop(listener, owner, token, binding, executor, opts) end)
      {:ok, %{listener: listener, acceptor: acceptor, url: "http://127.0.0.1:#{port}/mcp", token: token}}
    end
  end

  @spec stop(bridge()) :: :ok
  def stop(%{listener: listener, acceptor: acceptor}) do
    :gen_tcp.close(listener)
    if Process.alive?(acceptor), do: Process.exit(acceptor, :normal)
    :ok
  end

  @doc false
  @spec dispatch(map(), map(), keyword()) :: map()
  def dispatch(%{"method" => "initialize", "id" => id}, _binding, _opts) do
    result(id, %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "symphony", "version" => "1"}
    })
  end

  def dispatch(%{"method" => "notifications/initialized"}, _binding, _opts), do: %{}

  def dispatch(%{"method" => "tools/list", "id" => id}, binding, _opts) do
    tools =
      Enum.map(binding.tool_specs, fn spec ->
        %{
          "name" => spec["name"],
          "description" => spec["description"],
          "inputSchema" => spec["inputSchema"] || spec["input_schema"] || %{"type" => "object"}
        }
      end)

    result(id, %{"tools" => tools})
  end

  def dispatch(%{"method" => "tools/call", "id" => id, "params" => params}, binding, opts) do
    executor = Keyword.get(opts, :tool_executor, &DynamicTool.execute/4)
    context = Keyword.get(opts, :context, [])
    response = executor.(params["name"], params["arguments"] || %{}, binding, context)

    result(id, %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(response)}],
      "isError" => response["success"] == false
    })
  end

  def dispatch(%{"id" => id}, _binding, _opts),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32_601, "message" => "Method not found"}}

  def dispatch(_request, _binding, _opts), do: %{}

  defp result(id, value), do: %{"jsonrpc" => "2.0", "id" => id, "result" => value}

  defp accept_loop(listener, owner, token, binding, executor, opts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, token, binding, Keyword.put(opts, :tool_executor, executor)) end)
        accept_loop(listener, owner, token, binding, executor, opts)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(owner, {:antigravity_mcp_error, reason})
    end
  end

  defp serve(socket, token, binding, opts) do
    response =
      with {:ok, request} <- read_request(socket),
           true <- authorized?(request.headers, token),
           {:ok, payload} <- Jason.decode(request.body) do
        {200, dispatch(payload, binding, opts)}
      else
        false -> {401, %{"error" => "unauthorized"}}
        _ -> {400, %{"error" => "invalid request"}}
      end

    send_response(socket, response)
    :gen_tcp.close(socket)
  end

  defp read_request(socket), do: read_request(socket, "")

  defp read_request(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [raw_headers, body] ->
        headers = parse_headers(raw_headers)
        length = headers |> Map.get("content-length", "0") |> String.to_integer()

        if byte_size(body) >= length do
          {:ok, %{headers: headers, body: binary_part(body, 0, length)}}
        else
          receive_request_data(socket, buffer)
        end

      _ ->
        receive_request_data(socket, buffer)
    end
  rescue
    _ -> {:error, :invalid_http_request}
  end

  defp receive_request_data(socket, buffer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_request(socket, buffer <> data)
      error -> error
    end
  end

  defp parse_headers(raw) do
    raw
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> Map.put(acc, String.downcase(String.trim(name)), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp authorized?(headers, token), do: headers["authorization"] == "Bearer #{token}"

  defp send_response(socket, {status, payload}) do
    body = Jason.encode!(payload)
    reason = if status == 200, do: "OK", else: "Error"

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
    )
  end
end
