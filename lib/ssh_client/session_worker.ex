defmodule SSHClient.SessionWorker do
  @moduledoc """
  Decoupled SSH session worker GenServer managing an isolated SSH connection
  and PTY channel.

  Features:
  1. Finite state machine: `:disconnected`, `:connecting`, `:connected`,
     `:reconnecting`, `:disconnecting`, `:error`.
  2. Resilient terminal RingBuffer storing scrollback snapshot so LiveViews can
     detach and attach anytime without missing history or terminating the connection.
  3. PubSub output broadcasting to "ssh_client:session:<id>".
  4. Exponential reconnect backoff on unexpected disconnection.
  """

  use GenServer, restart: :temporary

  alias SSHClient.ActivityLog
  alias SSHClient.Config.Server
  alias SSHClient.SSH
  alias SSHClient.Terminal.Buffer

  @backoff_intervals [1_000, 2_000, 5_000, 10_000, 30_000]
  @max_reconnect_attempts 5

  defstruct [
    :session_id,
    :server,
    :connection,
    :channel_id,
    :buffer,
    :connect_task,
    :reconnect_timer,
    :user,
    :password,
    :auth_method,
    status: :disconnected,
    error_reason: nil,
    reconnect_attempts: 0,
    cols: 80,
    rows: 24,
    term: "xterm-256color"
  ]

  @type status :: :disconnected | :connecting | :connected | :reconnecting | :disconnecting | :error

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a SessionWorker GenServer.
  Options:
    - `:session_id` (required): Unique ID for the session
    - `:server` (required): %Server{} target config
    - `:cols`: Initial columns (default: 80)
    - `:rows`: Initial rows (default: 24)
    - `:term`: Terminal type (default: "xterm-256color")
    - `:user`: Optional override username
    - `:password`: Optional override password
    - `:auth_method`: Optional auth method preference
    - `:auto_connect`: Boolean, default true
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Sends raw binary input data to the PTY channel.
  """
  def send_input(worker, data) when is_binary(data) do
    GenServer.call(worker, {:send_input, data})
  end

  @doc """
  Resizes the terminal window dimensions and internal buffer.
  """
  def resize(worker, cols, rows) when is_integer(cols) and is_integer(rows) do
    GenServer.call(worker, {:resize, cols, rows})
  end

  @doc """
  Returns the current terminal screen buffer snapshot map.
  """
  def get_buffer(worker) do
    GenServer.call(worker, :get_buffer)
  end

  @doc """
  Retrieves the current worker state machine status.
  """
  def get_status(worker) do
    GenServer.call(worker, :get_status)
  end

  @doc """
  Disconnects the active session and cancels any reconnect timers.
  """
  def disconnect(worker) do
    GenServer.call(worker, :disconnect)
  end

  @doc """
  Triggers a connection or reconnection attempt immediately.
  """
  def reconnect(worker) do
    GenServer.call(worker, :reconnect)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    %Server{} = server = Keyword.fetch!(opts, :server)
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    term = Keyword.get(opts, :term, "xterm-256color")
    user = Keyword.get(opts, :user)
    password = Keyword.get(opts, :password)
    auth_method = Keyword.get(opts, :auth_method)
    auto_connect = Keyword.get(opts, :auto_connect, true)
    buffer = Buffer.new(cols, rows)

    state = %__MODULE__{
      session_id: session_id,
      server: server,
      cols: cols,
      rows: rows,
      term: term,
      user: user,
      password: password,
      auth_method: auth_method,
      buffer: buffer,
      status: :disconnected,
      reconnect_attempts: 0
    }

    if auto_connect do
      {:ok, state, {:continue, :connect}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, initiate_connection(state)}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:get_buffer, _from, state) do
    snapshot =
      if state.buffer do
        Buffer.to_snapshot(state.buffer)
      else
        %{cols: state.cols, rows: state.rows, text: "", html_lines: []}
      end

    {:reply, snapshot, state}
  end

  @impl true
  def handle_call({:send_input, data}, _from, %{connection: %SSH.Connection{} = conn, channel_id: channel_id, status: :connected} = state)
      when is_binary(data) and not is_nil(channel_id) do
    SSH.send_pty_data(conn, channel_id, data)
    {:reply, :ok, state}
  end

  def handle_call({:send_input, _data}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:resize, cols, rows}, _from, %{connection: %SSH.Connection{} = conn, channel_id: channel_id, status: :connected} = state)
      when is_integer(cols) and is_integer(rows) and not is_nil(channel_id) do
    SSH.resize_pty(conn, channel_id, cols, rows)
    new_buf = if state.buffer, do: Buffer.resize(state.buffer, cols, rows), else: nil
    {:reply, :ok, %{state | cols: cols, rows: rows, buffer: new_buf}}
  end

  def handle_call({:resize, cols, rows}, _from, state) when is_integer(cols) and is_integer(rows) do
    new_buf = if state.buffer, do: Buffer.resize(state.buffer, cols, rows), else: nil
    {:reply, :ok, %{state | cols: cols, rows: rows, buffer: new_buf}}
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    new_state = do_disconnect(state)
    new_state = set_status(new_state, :disconnected)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:reconnect, _from, state) do
    cleaned = do_disconnect(state)
    cleaned = %{cleaned | reconnect_attempts: 0}
    new_state = initiate_connection(cleaned)
    {:reply, :ok, new_state}
  end

  # Connect task result handler
  @impl true
  def handle_info({ref, result}, %{connect_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | connect_task: nil}

    case result do
      {:ok, conn, channel_id} ->
        target_user = state.user || state.server.user || "default"
        ActivityLog.info(
          state.server.id,
          "Session '#{state.session_id}' connected as '#{target_user}'"
        )

        new_state =
          state
          |> set_status(:connected)
          |> Map.put(:connection, conn)
          |> Map.put(:channel_id, channel_id)
          |> Map.put(:reconnect_attempts, 0)
          |> Map.put(:error_reason, nil)

        {:noreply, new_state}

      {:error, reason} ->
        ActivityLog.error(
          state.server.id,
          "Session '#{state.session_id}' connect failed: #{inspect(reason)}",
          reason
        )

        broadcast_error(state.session_id, reason)
        new_state = %{state | error_reason: reason}
        {:noreply, schedule_reconnect(new_state)}
    end
  end

  # Connect task crash
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{connect_task: %Task{ref: ref}} = state) do
    state = %{state | connect_task: nil}

    if reason != :normal do
      ActivityLog.error(
        state.server.id,
        "Session '#{state.session_id}' connect task crashed: #{inspect(reason)}",
        reason
      )

      broadcast_error(state.session_id, reason)
      new_state = %{state | error_reason: reason}
      {:noreply, schedule_reconnect(new_state)}
    else
      {:noreply, state}
    end
  end

  # Scheduled reconnect timer tick
  @impl true
  def handle_info(:scheduled_reconnect, state) do
    state = %{state | reconnect_timer: nil}
    {:noreply, initiate_connection(state)}
  end

  # Incoming PTY data from SSH connection
  @impl true
  def handle_info({:ssh_cm, _conn_ref, {:data, channel_id, 0, data}}, state) do
    if channel_id == state.channel_id do
      new_buf = if state.buffer, do: Buffer.feed(state.buffer, data), else: nil
      broadcast_pty_output(state.session_id, data)
      {:noreply, %{state | buffer: new_buf}}
    else
      {:noreply, state}
    end
  end

  # Simulate incoming data (for unit testing without active SSH socket)
  @impl true
  def handle_info({:simulate_data, data}, state) do
    new_buf = if state.buffer, do: Buffer.feed(state.buffer, data), else: nil
    broadcast_pty_output(state.session_id, data)
    {:noreply, %{state | buffer: new_buf}}
  end

  # EOF from SSH channel
  @impl true
  def handle_info({:ssh_cm, _conn_ref, {:eof, channel_id}}, state) do
    if channel_id == state.channel_id do
      ActivityLog.info(state.server.id, "Session '#{state.session_id}' received EOF")
    end

    {:noreply, state}
  end

  # Exit status from remote process
  @impl true
  def handle_info({:ssh_cm, _conn_ref, {:exit_status, channel_id, exit_code}}, state) do
    if channel_id == state.channel_id do
      ActivityLog.info(
        state.server.id,
        "Session '#{state.session_id}' exited with code #{exit_code}"
      )
    end

    new_state = do_disconnect(state)
    new_state = set_status(new_state, :disconnected)
    {:noreply, new_state}
  end

  # Remote channel closed unexpectedly
  @impl true
  def handle_info({:ssh_cm, _conn_ref, {:closed, channel_id}}, state) do
    if channel_id == state.channel_id do
      ActivityLog.info(state.server.id, "Session '#{state.session_id}' remote channel closed")
      cleaned = do_disconnect(state)
      {:noreply, schedule_reconnect(cleaned)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_disconnect(state)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal Connection & Reconnect Logic
  # ---------------------------------------------------------------------------

  defp initiate_connection(state) do
    # Cancel any pending reconnect timer
    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    state = set_status(state, :connecting)

    server = state.server
    user = state.user
    password = state.password
    auth_method = state.auth_method
    cols = state.cols
    rows = state.rows
    term = state.term

    task =
      Task.async(fn ->
        connect_opts =
          []
          |> (fn o -> if user, do: [{:user, user} | o], else: o end).()
          |> (fn o -> if password, do: [{:password, password} | o], else: o end).()
          |> (fn o -> if auth_method, do: [{:auth_method, auth_method} | o], else: o end).()

        case SSH.connect(server, connect_opts) do
          {:ok, conn} ->
            case SSH.open_pty(conn, cols: cols, rows: rows, term: term) do
              {:ok, channel_id} ->
                {:ok, conn, channel_id}

              {:error, reason} ->
                SSH.close(conn)
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end)

    %{state | connect_task: task, reconnect_timer: nil}
  end

  defp schedule_reconnect(state) do
    attempts = state.reconnect_attempts

    if attempts < @max_reconnect_attempts do
      delay = Enum.at(@backoff_intervals, attempts, 30_000)
      state = set_status(state, :reconnecting)
      timer = Process.send_after(self(), :scheduled_reconnect, delay)
      %{state | reconnect_attempts: attempts + 1, reconnect_timer: timer}
    else
      state = set_status(state, :error)
      %{state | reconnect_timer: nil}
    end
  end

  defp do_disconnect(state) do
    if state.connect_task do
      Task.shutdown(state.connect_task, :brutal_kill)
    end

    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    if state.connection && state.channel_id do
      SSH.close_pty(state.connection, state.channel_id)
      SSH.close(state.connection)
    end

    %{
      state
      | connect_task: nil,
        reconnect_timer: nil,
        connection: nil,
        channel_id: nil
    }
  end

  defp set_status(state, new_status) do
    if state.status != new_status do
      broadcast_status(state.session_id, new_status)
    end

    %{state | status: new_status}
  end

  # ---------------------------------------------------------------------------
  # PubSub Helpers
  # ---------------------------------------------------------------------------

  defp broadcast_status(session_id, status) do
    broadcast(session_id, {:session_status, session_id, status})
  end

  defp broadcast_pty_output(session_id, data) do
    broadcast(session_id, {:pty_output, session_id, data})
  end

  defp broadcast_error(session_id, reason) do
    broadcast(session_id, {:session_error, session_id, reason})
  end

  defp broadcast(session_id, message) do
    topic = "ssh_client:session:#{session_id}"

    try do
      Phoenix.PubSub.broadcast(SSHClient.PubSub, topic, message)
    rescue
      _ -> :ok
    end
  end
end
