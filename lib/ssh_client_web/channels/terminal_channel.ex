defmodule SSHClientWeb.TerminalChannel do
  @moduledoc """
  Phoenix Channel bridging terminal I/O between WebSocket clients and backend terminal sessions.

  Note: The primary interactive terminal stack in ssh-client uses `SSHClient.SessionWorker`,
  `SSHClient.SessionManager`, and Phoenix LiveView with ring buffers. This channel is maintained
  for compatibility and supports forwarding to both `SessionWorker` and legacy `PTYSession` processes.
  """

  use Phoenix.Channel

  alias SSHClient.SSH.PTYSession
  alias SSHClient.SessionManager
  alias SSHClient.SessionWorker

  @bracketed_paste_start "\e[200~"
  @bracketed_paste_end "\e[201~"

  @impl true
  def join("terminal:" <> server_id, payload, socket) do
    cols = Map.get(payload, "cols", 80)
    rows = Map.get(payload, "rows", 24)

    session_pid =
      case SessionManager.list_for_server(server_id) do
        [first | _] -> first.pid
        _ -> nil
      end

    socket =
      socket
      |> assign(:server_id, server_id)
      |> assign(:session_pid, session_pid)
      |> assign(:cols, cols)
      |> assign(:rows, rows)

    {:ok, %{status: "connected", server_id: server_id}, socket}
  end

  def join(_other, _payload, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  @impl true
  def handle_in("pty:input", %{"data" => data, "bracketed" => true}, socket)
      when is_binary(data) do
    wrapped = @bracketed_paste_start <> data <> @bracketed_paste_end
    handle_in("pty:input", %{"data" => wrapped}, socket)
  end

  def handle_in("pty:paste", %{"data" => data}, socket) when is_binary(data) do
    wrapped = @bracketed_paste_start <> data <> @bracketed_paste_end
    handle_in("pty:input", %{"data" => wrapped}, socket)
  end

  def handle_in("pty:input", %{"data" => data}, socket) when is_binary(data) do
    pid = resolve_session_pid(socket)

    if pid && Process.alive?(pid) do
      dispatch_input(pid, data)
    end

    {:reply, :ok, socket}
  end

  def handle_in("pty:resize", %{"cols" => cols, "rows" => rows}, socket)
      when is_integer(cols) and is_integer(rows) do
    pid = resolve_session_pid(socket)

    if pid && Process.alive?(pid) do
      dispatch_resize(pid, cols, rows)
    end

    {:reply, :ok, assign(socket, cols: cols, rows: rows)}
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @doc """
  Wraps multi-line or paste content in ANSI bracketed paste escape sequences.
  """
  def wrap_bracketed_paste(text) when is_binary(text) do
    @bracketed_paste_start <> text <> @bracketed_paste_end
  end

  defp resolve_session_pid(socket) do
    pid = socket.assigns[:session_pid]

    if pid && Process.alive?(pid) do
      pid
    else
      server_id = socket.assigns[:server_id]

      if server_id do
        case SessionManager.list_for_server(server_id) do
          [first | _] -> first.pid
          _ -> nil
        end
      end
    end
  end

  defp dispatch_input(pid, data) when is_pid(pid) and is_binary(data) do
    try do
      cond do
        match?({:ok, _}, SessionWorker.get_status(pid)) ->
          SessionWorker.send_input(pid, data)

        true ->
          PTYSession.send_input(pid, data)
      end
    rescue
      _ ->
        PTYSession.send_input(pid, data)
    end
  end

  defp dispatch_resize(pid, cols, rows) when is_pid(pid) do
    try do
      cond do
        match?({:ok, _}, SessionWorker.get_status(pid)) ->
          SessionWorker.resize(pid, cols, rows)

        true ->
          PTYSession.resize(pid, cols, rows)
      end
    rescue
      _ ->
        PTYSession.resize(pid, cols, rows)
    end
  end
end
