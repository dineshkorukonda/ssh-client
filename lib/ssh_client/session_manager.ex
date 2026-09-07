defmodule SSHClient.SessionManager do
  @moduledoc """
  Coordinates SessionWorkers under SessionSupervisor and maintains active session registry.
  """

  use GenServer

  alias SSHClient.Config.Server
  alias SSHClient.SessionSupervisor
  alias SSHClient.SessionWorker

  @name __MODULE__

  defstruct [
    :supervisor,
    sessions: %{},
    monitors: %{}
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the SessionManager GenServer coordinator.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates and starts a new session worker under SessionSupervisor.
  """
  def create_session(server, opts \\ []) when is_list(opts) do
    create_session(@name, server, opts)
  end

  def create_session(manager, server, opts)
      when (is_pid(manager) or is_atom(manager)) and is_list(opts) do
    GenServer.call(manager, {:create_session, server, opts})
  end

  @doc """
  Retrieves the PID of an active session worker by session ID.
  """
  def get_session(session_id), do: get_session(@name, session_id)

  def get_session(manager, session_id) when is_pid(manager) or is_atom(manager) do
    GenServer.call(manager, {:get_session, session_id})
  end

  @doc """
  Lists all active sessions with their metadata and current status.
  """
  def list_sessions(manager \\ @name) when is_pid(manager) or is_atom(manager) do
    GenServer.call(manager, :list_sessions)
  end

  @doc """
  Terminates a session worker and removes it from the registry.
  """
  def close_session(session_id), do: close_session(@name, session_id)

  def close_session(manager, session_id) when is_pid(manager) or is_atom(manager) do
    GenServer.call(manager, {:close_session, session_id})
  end

  @doc """
  Returns whether a session ID currently exists in the registry and is alive.
  """
  def has_session?(session_id), do: has_session?(@name, session_id)

  def has_session?(manager, session_id) when is_pid(manager) or is_atom(manager) do
    case get_session(manager, session_id) do
      {:ok, pid} when is_pid(pid) -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    supervisor = Keyword.get(opts, :supervisor, SessionSupervisor)

    state = %__MODULE__{
      supervisor: supervisor,
      sessions: %{},
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:create_session, server_or_map, opts}, _from, state) do
    case parse_server(server_or_map) do
      {:ok, %Server{} = server} ->
        session_id =
          opts
          |> Keyword.get(:session_id)
          |> normalize_session_id()

        if Map.has_key?(state.sessions, session_id) do
          {:reply, {:error, :already_exists}, state}
        else
          worker_opts =
            opts
            |> Keyword.put(:session_id, session_id)
            |> Keyword.put(:server, server)

          case SessionSupervisor.start_worker(state.supervisor, worker_opts) do
            {:ok, pid} ->
              ref = Process.monitor(pid)
              now = DateTime.utc_now()

              session_entry = %{
                session_id: session_id,
                pid: pid,
                server: server,
                monitor_ref: ref,
                created_at: now
              }

              new_sessions = Map.put(state.sessions, session_id, session_entry)
              new_monitors = Map.put(state.monitors, ref, session_id)

              {:reply, {:ok, session_id},
               %{state | sessions: new_sessions, monitors: new_monitors}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{pid: pid} ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, state}
        else
          {:reply, {:error, :not_found}, state}
        end

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    sessions =
      state.sessions
      |> Map.values()
      |> Enum.sort_by(& &1.created_at, {:asc, DateTime})
      |> Enum.map(fn entry ->
        status =
          if Process.alive?(entry.pid) do
            try do
              SessionWorker.get_status(entry.pid)
            rescue
              _ -> :unknown
            catch
              :exit, _ -> :disconnected
            end
          else
            :disconnected
          end

        %{
          session_id: entry.session_id,
          pid: entry.pid,
          server: entry.server,
          status: status,
          created_at: entry.created_at
        }
      end)

    {:reply, sessions, state}
  end

  @impl true
  def handle_call({:close_session, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{pid: pid, monitor_ref: ref} ->
        Process.demonitor(ref, [:flush])
        _ = SessionSupervisor.stop_worker(state.supervisor, pid)
        new_sessions = Map.delete(state.sessions, session_id)
        new_monitors = Map.delete(state.monitors, ref)
        {:reply, :ok, %{state | sessions: new_sessions, monitors: new_monitors}}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {session_id, new_monitors} when not is_nil(session_id) ->
        new_sessions = Map.delete(state.sessions, session_id)
        {:noreply, %{state | sessions: new_sessions, monitors: new_monitors}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp parse_server(%Server{} = server), do: {:ok, server}
  defp parse_server(attrs) when is_map(attrs), do: Server.from_map(attrs)
  defp parse_server(_other), do: {:error, :invalid_server}

  defp normalize_session_id(nil), do: generate_session_id()
  defp normalize_session_id(id) when is_binary(id) and byte_size(id) > 0, do: id
  defp normalize_session_id(_other), do: generate_session_id()

  defp generate_session_id do
    "sess_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
