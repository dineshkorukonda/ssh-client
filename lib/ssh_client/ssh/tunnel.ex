defmodule SSHClient.SSH.Tunnel do
  @moduledoc """
  Loopback direct-tcpip forwarding with one owner for the channel's entire lifetime.
  Keeping the opening process as owner also retains data sent immediately after
  channel confirmation, including the destination's initial SSH banner.
  """

  def open(connection, host, port, timeout) do
    case :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]) do
      {:ok, listener} ->
        {:ok, {_, local_port}} = :inet.sockname(listener)

        pid =
          spawn(fn ->
            receive do: (:start -> accept(listener, connection, host, port, timeout))
          end)

        case :gen_tcp.controlling_process(listener, pid) do
          :ok ->
            send(pid, :start)
            {:ok, {local_port, pid}}

          {:error, reason} ->
            Process.exit(pid, :kill)
            :gen_tcp.close(listener)
            {:error, reason}
        end

      error ->
        error
    end
  end

  defp accept(listener, connection, host, port, timeout) do
    monitor = Process.monitor(connection)

    try do
      accept_loop(listener, connection, host, port, timeout, monitor)
    after
      :gen_tcp.close(listener)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp accept_loop(listener, connection, host, port, timeout, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^connection, _} -> :ok
      :stop -> :ok
    after
      0 ->
        case :gen_tcp.accept(listener, 100) do
          {:ok, socket} ->
            pid =
              spawn(fn ->
                receive do: (:start -> forward(socket, connection, host, port, timeout))
              end)

            case :gen_tcp.controlling_process(socket, pid) do
              :ok ->
                send(pid, :start)

              {:error, _} ->
                Process.exit(pid, :kill)
                :gen_tcp.close(socket)
            end

            accept_loop(listener, connection, host, port, timeout, monitor)

          {:error, :timeout} ->
            accept_loop(listener, connection, host, port, timeout, monitor)

          {:error, _} ->
            :ok
        end
    end
  end

  defp forward(socket, connection, host, port, timeout) do
    monitor = Process.monitor(connection)

    try do
      {:ok, {peer, peer_port}} = :inet.peername(socket)
      address = host |> to_string() |> :erlang.iolist_to_binary()
      origin = peer |> :inet.ntoa() |> to_string()

      payload =
        <<byte_size(address)::32, address::binary, port::32, byte_size(origin)::32,
          origin::binary, peer_port::32>>

      case :ssh_connection.open_channel(connection, ~c"direct-tcpip", payload, timeout) do
        {:ok, channel} ->
          try do
            :ok = :inet.setopts(socket, active: :once, send_timeout: timeout)
            relay(socket, connection, channel, monitor, timeout)
          after
            :ssh_connection.close(connection, channel)
          end

        {:error, _} ->
          :ok
      end
    catch
      :exit, _ -> :ok
    after
      :gen_tcp.close(socket)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp relay(socket, connection, channel, monitor, timeout) do
    receive do
      {:tcp, ^socket, data} ->
        with :ok <- :ssh_connection.send(connection, channel, data, timeout),
             :ok <- :inet.setopts(socket, active: :once) do
          relay(socket, connection, channel, monitor, timeout)
        end

      {:ssh_cm, ^connection, {:data, ^channel, _, data}} ->
        if :gen_tcp.send(socket, data) == :ok do
          :ssh_connection.adjust_window(connection, channel, byte_size(data))
          relay(socket, connection, channel, monitor, timeout)
        end

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        :gen_tcp.shutdown(socket, :write)
        relay(socket, connection, channel, monitor, timeout)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _} ->
        :ok

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        :ok

      {:DOWN, ^monitor, :process, ^connection, _} ->
        :ok

      _ ->
        relay(socket, connection, channel, monitor, timeout)
    end
  end
end
