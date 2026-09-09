defmodule SSHClient.SSH.Forwarding do
  @moduledoc """
  Local and remote SSH TCP forwarding. Each rule keeps an independent SSH connection.
  """

  use GenServer

  alias SSHClient.SSH

  @name __MODULE__

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start_local(server, listen_port, dest_host, dest_port, opts \\ []) do
    GenServer.call(@name, {:start, :local, server, listen_port, dest_host, dest_port, opts})
  end

  def start_remote(server, listen_port, dest_host, dest_port, opts \\ []) do
    GenServer.call(@name, {:start, :remote, server, listen_port, dest_host, dest_port, opts})
  end

  def list, do: GenServer.call(@name, :list)
  def stop(id), do: GenServer.call(@name, {:stop, id})

  @impl true
  def init(_opts), do: {:ok, %{rules: %{}}}

  @impl true
  def handle_call({:start, type, server, listen_port, dest_host, dest_port, opts}, _from, state) do
    id = Keyword.get(opts, :id) || "fwd-" <> Integer.to_string(System.unique_integer([:positive]))
    auto = Keyword.get(opts, :auto_connect, true)

    rule = %{
      id: id,
      type: type,
      server_id: server_id(server),
      listen_port: listen_port,
      dest_host: dest_host,
      dest_port: dest_port,
      status: :idle,
      error: nil,
      conn: nil,
      bound_port: nil
    }

    if auto do
      case open_tunnel(type, server, listen_port, dest_host, dest_port) do
        {:ok, conn, bound} ->
          rule = %{rule | status: :active, conn: conn, bound_port: bound}
          {:reply, {:ok, id}, put_in(state.rules[id], rule)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:ok, id}, put_in(state.rules[id], rule)}
    end
  end

  def handle_call(:list, _from, state) do
    list =
      state.rules
      |> Map.values()
      |> Enum.map(&Map.drop(&1, [:conn]))

    {:reply, list, state}
  end

  def handle_call({:stop, id}, _from, state) do
    case Map.pop(state.rules, id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {rule, rest} ->
        if rule.conn, do: SSH.close(rule.conn)
        {:reply, :ok, %{state | rules: rest}}
    end
  end

  defp open_tunnel(:local, server, listen_port, dest_host, dest_port) do
    with {:ok, conn} <- SSH.connect(server) do
      case :ssh.tcpip_tunnel_to_server(
             conn.conn_ref,
             ~c"127.0.0.1",
             listen_port,
             String.to_charlist(dest_host),
             dest_port
           ) do
        {:ok, bound} ->
          {:ok, conn, bound}

        {:error, reason} ->
          SSH.close(conn)
          {:error, reason}
      end
    end
  end

  defp open_tunnel(:remote, server, listen_port, dest_host, dest_port) do
    with {:ok, conn} <- SSH.connect(server) do
      case :ssh.tcpip_tunnel_from_server(
             conn.conn_ref,
             ~c"127.0.0.1",
             listen_port,
             String.to_charlist(dest_host),
             dest_port
           ) do
        {:ok, bound} ->
          {:ok, conn, bound}

        {:error, reason} ->
          SSH.close(conn)
          {:error, reason}
      end
    end
  end

  defp server_id(%{id: id}), do: id
  defp server_id(%{"id" => id}), do: id
  defp server_id(_), do: nil
end
