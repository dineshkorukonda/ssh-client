defmodule SSHClient.ServerWorker do
  @moduledoc """
  GenServer maintaining state machine and monitoring loop for an individual server.
  States: :connecting -> :polling -> :degraded -> :reconnecting.
  """

  use GenServer, restart: :permanent

  alias SSHClient.ActivityLog
  alias SSHClient.Config.Server
  alias SSHClient.InitSystem
  alias SSHClient.Notifier
  alias SSHClient.SSH
  alias SSHClient.Metrics
  alias SSHClient.ServiceChecks

  @type status :: :connecting | :polling | :degraded | :reconnecting

  defstruct [
    :server,
    :connection,
    :init_system,
    :runner,
    status: :connecting,
    metrics: %{},
    checks: %{},
    consecutive_failures: 0,
    poll_interval: 5000,
    background_poll_interval: 30_000,
    focused?: true,
    reconnect_interval: 2000,
    last_error: nil,
    updated_at: nil
  ]

  @doc """
  Starts a ServerWorker for a given server configuration.
  """
  def start_link(server_or_opts, opts \\ [])

  def start_link({%Server{} = server, opts}, _default_opts) do
    start_link(server, opts)
  end

  def start_link(%Server{} = server, opts) do
    gen_opts =
      case Keyword.get(opts, :name, :default) do
        :default ->
          if Process.whereis(SSHClient.WorkerRegistry) do
            [name: via_registry(server.id)]
          else
            []
          end

        nil ->
          []

        name ->
          [name: name]
      end

    GenServer.start_link(__MODULE__, {server, opts}, gen_opts)
  end

  def start_link(opts_list, opts) when is_list(opts_list) do
    server = Keyword.fetch!(opts_list, :server)
    start_link(server, opts)
  end

  @doc """
  Returns the full snapshot state of a server worker.
  """
  def get_state(worker) do
    GenServer.call(resolve_worker(worker), :get_state)
  end

  @doc """
  Returns the current status of a server worker (:connecting | :polling | :degraded | :reconnecting).
  """
  def get_status(worker) do
    GenServer.call(resolve_worker(worker), :get_status)
  end

  @doc """
  Manually triggers a poll on the server worker.
  """
  def poll_now(worker) do
    GenServer.call(resolve_worker(worker), :poll_now)
  end

  @doc """
  Forces a reconnection attempt.
  """
  def reconnect(worker) do
    GenServer.call(resolve_worker(worker), :reconnect)
  end

  @doc """
  Returns the underlying Server configuration struct.
  """
  def get_server_config(worker) do
    GenServer.call(resolve_worker(worker), :get_server_config)
  end

  @doc """
  Sets the focus state of the server. When focused, polls at normal interval;
  when unfocused (backgrounded), backs off to background_poll_interval.
  """
  def set_focus(worker, focused?) when is_boolean(focused?) do
    GenServer.call(resolve_worker(worker), {:set_focus, focused?})
  end

  @doc """
  Looks up the worker pid in the registry for a server id.
  """
  def whereis(server_id) when is_binary(server_id) do
    case Registry.lookup(SSHClient.WorkerRegistry, server_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    _ -> nil
  end

  def via_registry(server_id) do
    {:via, Registry, {SSHClient.WorkerRegistry, server_id}}
  end

  @doc """
  Public wrapper around resolve_worker/1 so external modules (e.g. ServiceAction) can
  locate the correct GenServer target without duplicating the logic.
  """
  def resolve_worker_pub(server_id), do: resolve_worker(server_id)

  # Server Callbacks

  @impl true
  def init({%Server{} = server, opts}) do
    runner = Keyword.get(opts, :runner, &default_runner/2)
    poll_interval = Keyword.get(opts, :poll_interval, 5000)
    reconnect_interval = Keyword.get(opts, :reconnect_interval, 2000)

    state = %__MODULE__{
      server: server,
      runner: runner,
      status: :connecting,
      poll_interval: poll_interval,
      reconnect_interval: reconnect_interval,
      updated_at: DateTime.utc_now()
    }

    auto_connect = Keyword.get(opts, :auto_connect, true)

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
  def handle_call(:get_state, _from, state) do
    snapshot = %{
      id: state.server.id,
      name: state.server.name,
      host: state.server.host,
      user: state.server.user,
      users: state.server.users,
      default_auth_method: state.server.default_auth_method,
      port: state.server.port || 22,
      proxy_jump: state.server.proxy_jump,
      status: state.status,
      metrics: state.metrics,
      checks: state.checks,
      init_system: state.init_system,
      last_error: state.last_error,
      updated_at: state.updated_at
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_call(:get_server_config, _from, state) do
    {:reply, state.server, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    new_state = do_poll(state)
    {:reply, {:ok, new_state.status}, new_state}
  end

  @impl true
  def handle_call(:reconnect, _from, state) do
    close_connection(state)
    new_state = %{state | status: :connecting, connection: nil}
    {:reply, :ok, do_connect(new_state)}
  end

  @impl true
  def handle_call({:set_focus, focused?}, _from, state) do
    {:reply, :ok, %{state | focused?: focused?}}
  end

  @impl true
  def handle_call({:exec_cmd, cmd}, _from, state) do
    cond do
      is_nil(state.connection) ->
        {:reply, {:error, :not_connected}, state}

      state.status == :reconnecting ->
        {:reply, {:error, :reconnecting}, state}

      true ->
        result = state.runner.(state.server, {:exec, state.connection, cmd})

        case result do
          {:ok, output, _code} -> {:reply, {:ok, output}, state}
          {:ok, output} when is_binary(output) -> {:reply, {:ok, output}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info(:connect, state) do
    {:noreply, do_connect(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = do_poll(state)

    if new_state.status in [:polling, :degraded] do
      effective_interval =
        if new_state.focused? do
          new_state.poll_interval
        else
          new_state.background_poll_interval
        end

      schedule_poll(effective_interval)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:reconnect_timer, state) do
    {:noreply, do_connect(state)}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    close_connection(state)
    :ok
  end

  # Internal Logic

  defp do_connect(state) do
    old_status = state.status

    case state.runner.(state.server, :connect) do
      {:ok, conn} ->
        init_system = probe_init_system(state.server, conn, state.runner)

        new_state = %{
          state
          | connection: conn,
            init_system: init_system,
            status: :polling,
            consecutive_failures: 0,
            last_error: nil,
            updated_at: DateTime.utc_now()
        }

        schedule_poll(0)
        maybe_notify_transition(new_state, old_status)

      {:error, reason} ->
        schedule_reconnect(state.reconnect_interval)

        new_state = %{
          state
          | status: :reconnecting,
            connection: nil,
            last_error: reason,
            updated_at: DateTime.utc_now()
        }

        maybe_notify_transition(new_state, old_status)
    end
  end

  defp do_poll(%{status: :reconnecting} = state), do: state

  defp do_poll(state) do
    old_status = state.status

    case state.runner.(state.server, {:poll, state.connection, state.server.checks}) do
      {:ok, %{metrics: metrics, checks: checks, degraded: degraded}} ->
        new_status = if degraded, do: :degraded, else: :polling

        %{
          state
          | status: new_status,
            metrics: metrics,
            checks: checks,
            consecutive_failures: 0,
            last_error: nil,
            updated_at: DateTime.utc_now()
        }
        |> maybe_notify_transition(old_status)

      {:ok, %{metrics: metrics, checks: checks}} ->
        %{
          state
          | status: :polling,
            metrics: metrics,
            checks: checks,
            consecutive_failures: 0,
            last_error: nil,
            updated_at: DateTime.utc_now()
        }
        |> maybe_notify_transition(old_status)

      {:degraded, reason, partial_data} ->
        %{
          state
          | status: :degraded,
            metrics: Map.get(partial_data, :metrics, state.metrics),
            checks: Map.get(partial_data, :checks, state.checks),
            last_error: reason,
            updated_at: DateTime.utc_now()
        }
        |> maybe_notify_transition(old_status)

      {:error, :connection_lost} ->
        transition_to_reconnecting(state, :connection_lost)

      {:error, {:connection_failed, _} = reason} ->
        transition_to_reconnecting(state, reason)

      {:error, other_error} ->
        failures = state.consecutive_failures + 1

        if failures >= 3 do
          transition_to_reconnecting(state, other_error)
        else
          %{
            state
            | status: :degraded,
              consecutive_failures: failures,
              last_error: other_error,
              updated_at: DateTime.utc_now()
          }
          |> maybe_notify_transition(old_status)
        end
    end
  end

  defp transition_to_reconnecting(state, reason) do
    old_status = state.status
    close_connection(state)
    schedule_reconnect(state.reconnect_interval)

    %{
      state
      | status: :reconnecting,
        connection: nil,
        last_error: reason,
        updated_at: DateTime.utc_now()
    }
    |> maybe_notify_transition(old_status)
  end

  defp probe_init_system(server, conn, runner) do
    probe_fn = fn cmd -> runner.(server, {:exec, conn, cmd}) end

    case InitSystem.detect(probe_fn, server.id) do
      {:ok, init_sys} -> init_sys
      _ -> :unsupported
    end
  end

  defp close_connection(%{connection: conn, runner: runner, server: server})
       when not is_nil(conn) do
    try do
      runner.(server, {:close, conn})
    catch
      _, _ -> :ok
    end
  end

  defp close_connection(_), do: :ok

  defp schedule_poll(delay_ms) do
    Process.send_after(self(), :poll, delay_ms)
  end

  defp schedule_reconnect(delay_ms) do
    Process.send_after(self(), :reconnect_timer, delay_ms)
  end

  defp resolve_worker(pid) when is_pid(pid), do: pid

  defp resolve_worker(server_id) when is_binary(server_id) do
    case whereis(server_id) do
      pid when is_pid(pid) -> pid
      nil -> via_registry(server_id)
    end
  end

  defp resolve_worker(other), do: other

  defp default_runner(server, :connect) do
    SSH.connect(server)
  end

  defp default_runner(_server, {:close, conn}) do
    SSH.close(conn)
  end

  defp default_runner(_server, {:exec, conn, cmd}) do
    SSH.exec(conn, cmd)
  end

  defp default_runner(_server, {:poll, conn, checks}) do
    metrics_result =
      case Metrics.collect(conn) do
        {:ok, parsed} -> parsed
        _ -> %{}
      end

    uptime_result =
      case SSH.exec(conn, "uptime") do
        {:ok, output, 0} -> %{uptime: String.trim(output)}
        _ -> %{}
      end

    metrics = Map.merge(metrics_result, uptime_result)

    checks_result =
      case checks do
        nil ->
          %{}

        [] ->
          %{}

        list when is_list(list) ->
          case ServiceChecks.check_all(list, conn) do
            {:ok, res} -> res
            _ -> %{}
          end

        _ ->
          %{}
      end

    cond do
      map_size(metrics) > 0 ->
        {:ok, %{metrics: metrics, checks: checks_result}}

      map_size(checks_result) > 0 ->
        {:ok, %{metrics: metrics, checks: checks_result}}

      true ->
        {:degraded, :metrics_empty, %{metrics: metrics, checks: checks_result}}
    end
  end

  # Fires a desktop notification if the status actually changed to a new severity level.
  # Returns new_state unchanged — side-effecting only.
  # Arg order: (new_state, old_status) so it works as a pipe target.
  defp maybe_notify_transition(new_state, old_status) do
    if old_status != new_state.status do
      server_name = new_state.server.name || new_state.server.id
      Notifier.notify_state_change(server_name, old_status, new_state.status)

      log_level =
        case new_state.status do
          :reconnecting -> :error
          :degraded -> :warn
          _ -> :info
        end

      msg =
        case new_state.status do
          :polling -> "Connected and polling metrics"
          :reconnecting -> "Connection failed (#{inspect(new_state.last_error)}). Reconnecting..."
          :degraded -> "Degraded state (#{inspect(new_state.last_error)})"
          other -> "Status changed to #{other}"
        end

      ActivityLog.log(log_level, new_state.server.id, msg, new_state.last_error)
    end

    new_state
  end
end
