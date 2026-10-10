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
    :reconnect_timer,
    :user,
    :password,
    :auth_method,
    :connect_task,
    :connect_monitor,
    :attempt_id,
    :host_key_prompt,
    ssh_opts: [],
    output_seq: 0,
    output_chunks: [],
    status: :disconnected,
    error_reason: nil,
    reconnect_attempts: 0,
    cols: 80,
    rows: 24,
    term: "xterm-256color",
    input_queue: []
  ]

  @type status ::
          :disconnected | :connecting | :connected | :reconnecting | :disconnecting | :error

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
    - `:max_scrollback`: Integer max scrollback lines (default: 1000)
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

  def desktop_snapshot(worker, since \\ 0), do: GenServer.call(worker, {:desktop_snapshot, since})
  def connection(worker), do: GenServer.call(worker, :connection)
  def approve_host(worker), do: GenServer.call(worker, :approve_host)

  @doc """
  Disconnects the active session, transitioning through :disconnecting to :disconnected,
  and cancels any reconnect timers.
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
    max_scrollback = Keyword.get(opts, :max_scrollback, 1000)
    channel_id = Keyword.get(opts, :channel_id)
    buffer = Buffer.new(cols, rows, max_scrollback: max_scrollback)

    state = %__MODULE__{
      session_id: session_id,
      server: server,
      cols: cols,
      rows: rows,
      term: term,
      user: user,
      password: password,
      auth_method: auth_method,
      ssh_opts: Keyword.get(opts, :ssh_opts, []),
      channel_id: channel_id,
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
    {:noreply, do_connect(state)}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call({:desktop_snapshot, since}, _from, state) do
    prompt =
      case state.host_key_prompt do
        %{type: type, details: details} ->
          %{type: type, details: Map.drop(details, [:key, :known_hosts_file])}

        _ ->
          nil
      end

    chunks = state.output_chunks |> Enum.reverse() |> Enum.filter(fn {seq, _} -> seq > since end)

    oldest =
      case List.last(state.output_chunks) do
        {seq, _} -> seq
        nil -> state.output_seq + 1
      end

    snapshot = %{
      status: state.status,
      cursor: state.output_seq,
      reset: since < oldest - 1,
      screen: if(since < oldest - 1, do: Buffer.to_snapshot(state.buffer).text, else: nil),
      output: Enum.map(chunks, fn {seq, data} -> %{seq: seq, data: Base.encode64(data)} end),
      host_key_prompt: prompt,
      error: if(state.error_reason, do: SSH.plain_language_error(state.error_reason), else: nil)
    }

    {:reply, snapshot, state}
  end

  def handle_call(:connection, _from, %{status: :connected, connection: conn} = state),
    do: {:reply, {:ok, conn}, state}

  def handle_call(:connection, _from, state), do: {:reply, {:error, :not_connected}, state}

  def handle_call(
        :approve_host,
        _from,
        %{host_key_prompt: %{type: type, details: details}} = state
      ) do
    verifier = SSHClient.SSH.HostKeyVerifier
    opts = [known_hosts_file: details.known_hosts_file]

    result =
      if type == :host_key_changed,
        do: verifier.update_host_key(details.host, details.port, details.key, opts),
        else: verifier.save_host_key(details.host, details.port, details.key, opts)

    case result do
      :ok -> {:reply, :ok, do_connect(do_teardown(state))}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:approve_host, _from, state), do: {:reply, {:error, :no_host_key_prompt}, state}

  @impl true
  def handle_call(:get_buffer, _from, state) do
    snapshot =
      if state.buffer do
        Buffer.to_snapshot(state.buffer)
      else
        %{cols: state.cols, rows: state.rows, text: "", html_lines: [], scrollback_count: 0}
      end

    {:reply, snapshot, state}
  end

  @impl true
  def handle_call(
        {:send_input, data},
        _from,
        %{connection: %SSH.Connection{} = conn, channel_id: channel_id, status: :connected} =
          state
      )
      when is_binary(data) and not is_nil(channel_id) do
    SSH.send_pty_data(conn, channel_id, data)
    {:reply, :ok, state}
  end

  def handle_call({:send_input, data}, _from, state) when is_binary(data) do
    capped_queue = Enum.take([data | state.input_queue], 500)
    {:reply, :ok, %{state | input_queue: capped_queue}}
  end

  def handle_call({:send_input, _data}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(
        {:resize, cols, rows},
        _from,
        %{connection: %SSH.Connection{} = conn, channel_id: channel_id, status: :connected} =
          state
      )
      when is_integer(cols) and is_integer(rows) and not is_nil(channel_id) do
    SSH.resize_pty(conn, channel_id, cols, rows)
    new_buf = if state.buffer, do: Buffer.resize(state.buffer, cols, rows), else: nil
    {:reply, :ok, %{state | cols: cols, rows: rows, buffer: new_buf}}
  end

  def handle_call({:resize, cols, rows}, _from, state)
      when is_integer(cols) and is_integer(rows) do
    new_buf = if state.buffer, do: Buffer.resize(state.buffer, cols, rows), else: nil
    {:reply, :ok, %{state | cols: cols, rows: rows, buffer: new_buf}}
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    # Transition through :disconnecting before teardown
    state_disconnecting = set_status(state, :disconnecting)
    cleaned = do_teardown(state_disconnecting)
    final_state = set_status(cleaned, :disconnected)
    {:reply, :ok, final_state}
  end

  @impl true
  def handle_call(:reconnect, _from, state) do
    state_disconnecting = set_status(state, :disconnecting)
    cleaned = do_teardown(state_disconnecting)
    cleaned = %{cleaned | reconnect_attempts: 0}
    {:noreply, new_state} = handle_continue(:connect, cleaned)
    {:reply, :ok, new_state}
  end

  # Scheduled reconnect timer tick
  @impl true
  def handle_info(:scheduled_reconnect, state) do
    if state.status == :reconnecting do
      {:noreply, do_connect(%{state | reconnect_timer: nil})}
    else
      {:noreply, state}
    end
  end

  # Incoming PTY data from SSH connection (standard OTP :ssh channel message)
  @impl true
  def handle_info({:ssh_cm, conn_ref, {:data, channel_id, _type, data}}, state) do
    if current_channel?(state, conn_ref, channel_id) do
      new_buf = if state.buffer, do: Buffer.feed(state.buffer, data), else: nil
      broadcast_pty_output(state.session_id, data)
      seq = state.output_seq + 1
      chunks = Enum.take([{seq, data} | state.output_chunks], 256)
      {:noreply, %{state | buffer: new_buf, output_seq: seq, output_chunks: chunks}}
    else
      {:noreply, state}
    end
  end

  # EOF from SSH channel
  @impl true
  def handle_info({:ssh_cm, conn_ref, {:eof, channel_id}}, state) do
    if current_channel?(state, conn_ref, channel_id) do
      ActivityLog.info(state.server.id, "Session '#{state.session_id}' received EOF")
    end

    {:noreply, state}
  end

  # Exit status from remote process
  @impl true
  def handle_info({:ssh_cm, conn_ref, {:exit_status, channel_id, exit_code}}, state) do
    if current_channel?(state, conn_ref, channel_id) do
      ActivityLog.info(
        state.server.id,
        "Session '#{state.session_id}' exited with code #{exit_code}"
      )

      cleaned = do_teardown(set_status(state, :disconnecting))
      {:noreply, set_status(cleaned, :disconnected)}
    else
      {:noreply, state}
    end
  end

  # Remote channel closed unexpectedly
  @impl true
  def handle_info({:ssh_cm, conn_ref, {:closed, channel_id}}, state) do
    if current_channel?(state, conn_ref, channel_id) do
      ActivityLog.info(state.server.id, "Session '#{state.session_id}' remote channel closed")
      state_disconnecting = set_status(state, :disconnecting)
      cleaned = do_teardown(state_disconnecting)
      {:noreply, schedule_reconnect(cleaned)}
    else
      {:noreply, state}
    end
  end

  # Connection completed message from background connection Task
  @impl true
  def handle_info(
        {:connect_completed, attempt, result},
        %{attempt_id: attempt, status: :connecting} = state
      ) do
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

        try do
          SSHClient.ServerManager.mark_connected(state.server.id)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

        {:noreply, flush_input_queue(new_state)}

      {:error, reason} ->
        {:noreply, handle_connect_error(state, reason)}
    end
  end

  def handle_info({:connect_completed, _attempt, {:ok, conn, channel}}, state) do
    SSH.close_pty(conn, channel)
    SSH.close(conn)
    {:noreply, state}
  end

  def handle_info({:connect_completed, _attempt, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{connect_monitor: ref} = state) do
    cleaned = %{state | connect_task: nil, connect_monitor: nil}

    if state.status in [:connecting, :connected] do
      {:noreply, handle_connect_error(do_teardown(cleaned), {:connection_task_failed, reason})}
    else
      {:noreply, cleaned}
    end
  end

  @impl true
  def handle_info(
        {:ssh_host_key_event, attempt, event_type, details},
        %{attempt_id: attempt} = state
      ) do
    broadcast(state.session_id, {:ssh_host_key_event, state.session_id, event_type, details})
    {:noreply, %{state | host_key_prompt: %{type: event_type, details: details}}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_teardown(state)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Connection & Reconnect Implementation
  # ---------------------------------------------------------------------------

  defp do_connect(state) do
    # Cancel any pending reconnect timer
    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    attempt = make_ref()
    state = set_status(%{state | attempt_id: attempt, host_key_prompt: nil}, :connecting)

    server = state.server
    user = state.user
    password = state.password
    auth_method = state.auth_method
    cols = state.cols
    rows = state.rows
    term = state.term
    worker_pid = self()

    connect_opts =
      state.ssh_opts
      |> (fn o -> if user, do: [{:user, user} | o], else: o end).()
      |> (fn o -> if password, do: [{:password, password} | o], else: o end).()
      |> (fn o -> if auth_method, do: [{:auth_method, auth_method} | o], else: o end).()
      |> Keyword.put(:host_key_handler, fn type, details ->
        send(worker_pid, {:ssh_host_key_event, attempt, type, details})
      end)

    {task, monitor} =
      spawn_monitor(fn ->
        parent_monitor = Process.monitor(worker_pid)

        result =
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

        case result do
          {:ok, conn, _channel} ->
            try do
              send(worker_pid, {:connect_completed, attempt, result})
              relay_channel(worker_pid, parent_monitor)
            after
              SSH.close(conn)
            end

          _ ->
            send(worker_pid, {:connect_completed, attempt, result})
        end
      end)

    %{state | connect_task: task, connect_monitor: monitor}
  end

  defp relay_channel(worker, parent_monitor) do
    receive do
      {:ssh_cm, _, _} = message ->
        send(worker, message)
        relay_channel(worker, parent_monitor)

      :cancel ->
        :ok

      {:DOWN, ^parent_monitor, :process, ^worker, _} ->
        :ok
    end
  end

  defp current_channel?(%{connection: %SSH.Connection{conn_ref: ref}, channel_id: id}, ref, id),
    do: true

  defp current_channel?(_, _, _), do: false

  defp handle_connect_error(state, reason) do
    ActivityLog.error(
      state.server.id,
      "Session '#{state.session_id}' connect failed: #{inspect(reason)}",
      reason
    )

    broadcast_error(state.session_id, reason)
    new_state = %{state | error_reason: reason}

    if is_nil(state.host_key_prompt) and transient_error?(reason) do
      schedule_reconnect(new_state)
    else
      set_status(new_state, :error)
    end
  end

  defp transient_error?({:connection_failed, reason}), do: transient_error?(reason)

  defp transient_error?(reason),
    do: reason in [:timeout, :econnrefused, :ehostunreach, :enetunreach, :closed, :econnreset]

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

  defp do_teardown(state) do
    if state.connect_task, do: send(state.connect_task, :cancel)
    if state.connect_monitor, do: Process.demonitor(state.connect_monitor, [:flush])

    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    if state.connection && state.channel_id do
      SSH.close_pty(state.connection, state.channel_id)
      SSH.close(state.connection)
    end

    %{
      state
      | reconnect_timer: nil,
        connect_task: nil,
        connect_monitor: nil,
        attempt_id: nil,
        host_key_prompt: nil,
        connection: nil,
        channel_id: nil,
        input_queue: []
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

  defp flush_input_queue(%{input_queue: []} = state), do: state

  defp flush_input_queue(%{input_queue: queue, connection: conn, channel_id: channel_id} = state)
       when not is_nil(conn) and not is_nil(channel_id) do
    queue
    |> Enum.reverse()
    |> Enum.each(fn data -> SSH.send_pty_data(conn, channel_id, data) end)

    %{state | input_queue: []}
  end

  defp flush_input_queue(state), do: %{state | input_queue: []}
end
