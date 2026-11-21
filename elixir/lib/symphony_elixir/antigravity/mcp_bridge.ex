defmodule SymphonyElixir.Antigravity.McpBridge do
  @moduledoc false

  alias SymphonyElixir.Codex.DynamicTool

  @max_header_bytes 65_536
  @max_body_bytes 1_048_576

  @type bridge :: %{listener: port(), acceptor: pid(), url: String.t(), token: String.t()}

  @spec start(map(), keyword()) :: {:ok, bridge()} | {:error, term()}
  def start(binding, opts \\ []) do
    executor = Keyword.get(opts, :tool_executor, &DynamicTool.execute/4)
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    with {:ok, listener} <-
           :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]),
         {:ok, {_address, port}} <- :inet.sockname(listener) do
      owner = self()
      acceptor = spawn(fn -> accept_loop(listener, owner, token, binding, executor, opts) end)
      {:ok, %{listener: listener, acceptor: acceptor, url: "http://127.0.0.1:#{port}/mcp", token: token}}
    end
  end

  @spec stop(bridge()) :: :ok
  def stop(%{listener: listener, acceptor: acceptor}) do
    if Process.alive?(acceptor), do: Process.exit(acceptor, :shutdown)
    :gen_tcp.close(listener)
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
        spawn_link(fn -> serve(socket, token, binding, Keyword.put(opts, :tool_executor, executor)) end)
        accept_loop(listener, owner, token, binding, executor, opts)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(owner, {:antigravity_mcp_error, reason})
    end
  end

  defp serve(socket, token, binding, opts) do
    response =
      with {:ok, request} <- read_request(socket, token),
           :post <- request.method,
           {:ok, payload} when is_map(payload) <- Jason.decode(request.body) do
        if payload["method"] == "notifications/initialized" do
          {202, nil}
        else
          {200, dispatch(payload, binding, opts)}
        end
      else
        {:error, :unauthorized} -> {401, %{"error" => "unauthorized"}}
        {:error, :too_large} -> {413, %{"error" => "request too large"}}
        method when method in [:get, :other] -> {405, %{"error" => "method not allowed"}}
        _ -> {400, %{"error" => "invalid request"}}
      end

    send_response(socket, response)
  rescue
    _ -> send_response(socket, {400, %{"error" => "invalid request"}})
  after
    :gen_tcp.close(socket)
  end

  defp read_request(socket, token), do: read_request(socket, token, "")

  defp read_request(_socket, _token, buffer) when byte_size(buffer) > @max_header_bytes + @max_body_bytes,
    do: {:error, :too_large}

  defp read_request(socket, token, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [raw_headers, body] ->
        if byte_size(raw_headers) > @max_header_bytes do
          {:error, :too_large}
        else
          finish_request(socket, token, buffer, raw_headers, body)
        end

      _ ->
        receive_request_data(socket, token, buffer)
    end
  rescue
    _ -> {:error, :invalid_http_request}
  end

  defp finish_request(socket, token, buffer, raw_headers, body) do
    {method, headers} = parse_headers(raw_headers)
    length = headers |> Map.get("content-length", "0") |> String.to_integer()

    cond do
      not authorized?(headers, token) -> {:error, :unauthorized}
      length > @max_body_bytes -> {:error, :too_large}
      byte_size(body) >= length -> {:ok, %{method: method, headers: headers, body: binary_part(body, 0, length)}}
      true -> receive_request_data(socket, token, buffer)
    end
  end

  defp receive_request_data(socket, token, buffer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_request(socket, token, buffer <> data)
      error -> error
    end
  end

  defp parse_headers(raw) do
    [request_line | lines] = String.split(raw, "\r\n")

    method =
      if String.starts_with?(request_line, "POST "),
        do: :post,
        else: if(String.starts_with?(request_line, "GET "), do: :get, else: :other)

    headers =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [name, value] -> Map.put(acc, String.downcase(String.trim(name)), String.trim(value))
          _ -> acc
        end
      end)

    {method, headers}
  end

  defp authorized?(headers, token) do
    supplied = headers["authorization"] || ""
    expected = "Bearer #{token}"
    byte_size(supplied) == byte_size(expected) and Plug.Crypto.secure_compare(supplied, expected)
  end

  defp send_response(socket, {status, payload}) do
    body = if is_nil(payload), do: "", else: Jason.encode!(payload)
    reason = if status in [200, 202], do: "OK", else: "Error"

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
    )
  end
end
