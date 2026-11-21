defmodule SymphonyElixir.Antigravity.McpBridge do
  @moduledoc false

  alias SymphonyElixir.Antigravity.PeerAuth
  alias SymphonyElixir.Codex.DynamicTool

  @max_header_bytes 65_536
  @max_body_bytes 1_048_576
  @max_connections 16
  @request_timeout_ms 10_000

  @type bridge :: %{
          listener: port(),
          acceptor: pid(),
          peer_root: :atomics.atomics_ref(),
          url: String.t(),
          token: String.t()
        }

  @spec start(map(), keyword()) :: {:ok, bridge()} | {:error, term()}
  def start(binding, opts \\ []) do
    executor = Keyword.get(opts, :tool_executor, &DynamicTool.execute/4)
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    peer_root = :atomics.new(1, signed: true)
    :atomics.put(peer_root, 1, if(Keyword.get(opts, :require_process_binding, false), do: 0, else: -1))

    with {:ok, listener} <-
           :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]),
         {:ok, {_address, port}} <- :inet.sockname(listener) do
      owner = self()
      acceptor = spawn(fn -> accept_loop(listener, owner, token, binding, executor, opts, peer_root, %{}) end)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         peer_root: peer_root,
         url: "http://127.0.0.1:#{port}/mcp",
         token: token
       }}
    end
  end

  @spec authorize_process(bridge(), pos_integer()) :: :ok
  def authorize_process(%{peer_root: peer_root}, os_pid) when is_integer(os_pid) and os_pid > 0 do
    :atomics.put(peer_root, 1, os_pid)
    :ok
  end

  @spec stop(bridge()) :: :ok
  def stop(%{listener: listener, acceptor: acceptor}) do
    :gen_tcp.close(listener)
    if Process.alive?(acceptor), do: send(acceptor, :shutdown)
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

  def dispatch(%{"method" => "tools/call", "id" => id, "params" => params}, binding, opts) when is_map(params) do
    executor = Keyword.get(opts, :tool_executor, &DynamicTool.execute/4)
    context = Keyword.get(opts, :context, [])
    response = execute_tool(executor, params, binding, context)

    result(id, %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(response)}],
      "isError" => response["success"] == false
    })
  end

  def dispatch(%{"id" => id}, _binding, _opts),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32_601, "message" => "Method not found"}}

  def dispatch(_request, _binding, _opts), do: %{}

  defp result(id, value), do: %{"jsonrpc" => "2.0", "id" => id, "result" => value}

  defp execute_tool(executor, params, binding, context) do
    executor.(params["name"], params["arguments"] || %{}, binding, context)
  rescue
    error -> %{"success" => false, "error" => Exception.message(error)}
  catch
    kind, reason -> %{"success" => false, "error" => Exception.format(kind, reason, [])}
  end

  defp accept_loop(listener, owner, token, binding, executor, opts, peer_root, children) do
    children = reap_children(children)

    receive do
      :shutdown ->
        stop_children(children)
        :gen_tcp.close(listener)
    after
      0 -> continue_accepting(listener, owner, token, binding, executor, opts, peer_root, children)
    end
  end

  defp continue_accepting(listener, owner, token, binding, executor, opts, peer_root, children) do
    cond do
      not Process.alive?(owner) ->
        stop_children(children)
        :gen_tcp.close(listener)

      map_size(children) >= @max_connections ->
        receive do
          {:DOWN, reference, :process, _pid, _reason} ->
            accept_loop(listener, owner, token, binding, executor, opts, peer_root, Map.delete(children, reference))

          :shutdown ->
            stop_children(children)
            :gen_tcp.close(listener)
        after
          250 -> accept_loop(listener, owner, token, binding, executor, opts, peer_root, children)
        end

      true ->
        accept_connection(listener, owner, token, binding, executor, opts, peer_root, children)
    end
  end

  defp accept_connection(listener, owner, token, binding, executor, opts, peer_root, children) do
    case :gen_tcp.accept(listener, 1_000) do
      {:ok, socket} ->
        root_pid = :atomics.get(peer_root, 1)
        {pid, reference} = spawn_monitor(fn -> serve_authorized(socket, root_pid, token, binding, executor, opts) end)

        accept_loop(listener, owner, token, binding, executor, opts, peer_root, Map.put(children, reference, pid))

      {:error, :timeout} ->
        accept_loop(listener, owner, token, binding, executor, opts, peer_root, children)

      {:error, :closed} ->
        stop_children(children)
        :ok

      {:error, reason} ->
        send(owner, {:antigravity_mcp_error, reason})
    end
  end

  defp serve_authorized(socket, root_pid, token, binding, executor, opts) do
    if PeerAuth.authorized?(socket, root_pid) do
      serve(socket, token, binding, Keyword.put(opts, :tool_executor, executor))
    else
      send_response(socket, {401, %{"error" => "unauthorized process"}})
      :gen_tcp.close(socket)
    end
  end

  defp reap_children(children) do
    receive do
      {:DOWN, reference, :process, _pid, _reason} -> reap_children(Map.delete(children, reference))
    after
      0 -> children
    end
  end

  defp stop_children(children), do: Enum.each(children, fn {_reference, pid} -> Process.exit(pid, :shutdown) end)

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

  defp read_request(socket, token) do
    deadline = System.monotonic_time(:millisecond) + @request_timeout_ms
    read_request(socket, token, "", deadline)
  end

  defp read_request(_socket, _token, buffer, _deadline) when byte_size(buffer) > @max_header_bytes + @max_body_bytes,
    do: {:error, :too_large}

  defp read_request(socket, token, buffer, deadline) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [raw_headers, body] ->
        if byte_size(raw_headers) > @max_header_bytes do
          {:error, :too_large}
        else
          finish_request(socket, token, buffer, raw_headers, body, deadline)
        end

      _ ->
        receive_request_data(socket, token, buffer, deadline)
    end
  rescue
    _ -> {:error, :invalid_http_request}
  end

  defp finish_request(socket, token, buffer, raw_headers, body, deadline) do
    {method, headers} = parse_headers(raw_headers)
    length = headers |> Map.get("content-length", "0") |> String.to_integer()

    cond do
      not authorized?(headers, token) -> {:error, :unauthorized}
      length > @max_body_bytes -> {:error, :too_large}
      byte_size(body) >= length -> {:ok, %{method: method, headers: headers, body: binary_part(body, 0, length)}}
      true -> receive_request_data(socket, token, buffer, deadline)
    end
  end

  defp receive_request_data(socket, token, buffer, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case :gen_tcp.recv(socket, 0, min(5_000, remaining)) do
        {:ok, data} -> read_request(socket, token, buffer <> data, deadline)
        error -> error
      end
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
