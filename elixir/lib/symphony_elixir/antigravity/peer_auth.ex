defmodule SymphonyElixir.Antigravity.PeerAuth do
  @moduledoc false

  @spec authorized?(port(), integer()) :: boolean()
  def authorized?(_socket, -1), do: true
  def authorized?(_socket, root_pid) when root_pid <= 0, do: false

  def authorized?(socket, root_pid) do
    with {:ok, {_address, local_port}} <- :inet.sockname(socket),
         {:ok, {_address, peer_port}} <- :inet.peername(socket),
         {:ok, inode} <- socket_inode(local_port, peer_port),
         {:ok, peer_pid} <- inode_owner(inode) do
      peer_pid == root_pid or descendant?(peer_pid, root_pid)
    else
      _ -> false
    end
  end

  defp socket_inode(local_port, peer_port) do
    ["/proc/net/tcp", "/proc/net/tcp6"]
    |> Enum.find_value(&find_socket_inode(&1, local_port, peer_port))
    |> case do
      nil -> {:error, :peer_not_found}
      inode -> {:ok, inode}
    end
  end

  defp find_socket_inode(path, local_port, peer_port) do
    case File.read(path) do
      {:ok, contents} -> Enum.find_value(String.split(contents, "\n"), &matching_inode(&1, local_port, peer_port))
      _ -> nil
    end
  end

  defp matching_inode(line, local_port, peer_port) do
    case String.split(line) do
      [_slot, local, remote, "01" | fields] ->
        if endpoint_port(local) == local_port and endpoint_port(remote) == peer_port, do: Enum.at(fields, 5)

      _ ->
        nil
    end
  end

  defp endpoint_port(endpoint) do
    with [_address, hex_port] <- String.split(endpoint, ":"),
         {port, ""} <- Integer.parse(hex_port, 16) do
      port
    else
      _ -> nil
    end
  end

  defp inode_owner(inode) do
    Path.wildcard("/proc/[0-9]*/fd/*")
    |> Enum.find_value(&owner_for_fd(&1, inode))
    |> case do
      nil -> {:error, :peer_not_found}
      pid -> {:ok, pid}
    end
  end

  defp owner_for_fd(path, inode) do
    case File.read_link(path) do
      {:ok, "socket:[" <> rest} ->
        if String.trim_trailing(rest, "]") == inode, do: path_pid(path)

      _ ->
        nil
    end
  end

  defp path_pid(path) do
    case path |> Path.split() |> Enum.at(2) |> Integer.parse() do
      {pid, ""} -> pid
      _ -> nil
    end
  end

  defp descendant?(pid, root_pid), do: descendant?(pid, root_pid, MapSet.new())

  defp descendant?(pid, root_pid, seen) when pid > 1 do
    if MapSet.member?(seen, pid) do
      false
    else
      case parent_pid(pid) do
        ^root_pid -> true
        parent when is_integer(parent) -> descendant?(parent, root_pid, MapSet.put(seen, pid))
        _ -> false
      end
    end
  end

  defp descendant?(_pid, _root_pid, _seen), do: false

  defp parent_pid(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_prefix, suffix] <- String.split(stat, ") ", parts: 2),
         [_state, parent | _] <- String.split(suffix),
         {parent_pid, ""} <- Integer.parse(parent) do
      parent_pid
    else
      _ -> nil
    end
  end
end
