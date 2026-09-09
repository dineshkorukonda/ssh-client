defmodule SSHClient.ServerManager do
  @moduledoc """
  Coordinates ServerWorkers under ServerSupervisor, reconciling changes from servers.yaml.
  """

  use GenServer

  alias SSHClient.Config
  alias SSHClient.Config.Server
  alias SSHClient.ServerSupervisor
  alias SSHClient.ServerWorker

  @name __MODULE__

  defstruct [
    :config_path,
    :supervisor,
    :runner,
    workers: %{},
    poll_interval: 5000
  ]

  @doc """
  Starts the ServerManager coordinator process.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Synchronizes running workers with a Config struct or list of Server structs.
  Starts workers for new servers and stops workers for removed servers.
  """
  def sync_config(config_or_servers)
      when is_list(config_or_servers) or is_struct(config_or_servers, Config) do
    sync_config(@name, config_or_servers, [])
  end

  def sync_config(manager, config_or_servers)
      when (is_pid(manager) or is_atom(manager)) and
             (is_list(config_or_servers) or is_struct(config_or_servers, Config)) do
    sync_config(manager, config_or_servers, [])
  end

  def sync_config(config_or_servers, opts)
      when is_list(opts) and
             (is_list(config_or_servers) or is_struct(config_or_servers, Config)) do
    sync_config(@name, config_or_servers, opts)
  end

  def sync_config(manager, config_or_servers, opts) do
    GenServer.call(manager, {:sync_config, config_or_servers, opts})
  end

  @doc """
  Loads config from a YAML file and synchronizes running workers.
  """
  def sync_file do
    sync_file(@name, nil, [])
  end

  def sync_file(path) when is_binary(path) do
    sync_file(@name, path, [])
  end

  def sync_file(manager, path)
      when (is_pid(manager) or is_atom(manager)) and (is_binary(path) or is_nil(path)) do
    sync_file(manager, path, [])
  end

  def sync_file(path, opts) when is_binary(path) and is_list(opts) do
    sync_file(@name, path, opts)
  end

  def sync_file(manager, path, opts) do
    GenServer.call(manager, {:sync_file, path, opts})
  end

  @doc """
  Lists the current state snapshot of all running servers.
  """
  def list_servers(manager \\ @name) do
    GenServer.call(manager, :list_servers)
  end

  @doc """
  Returns the snapshot state for a specific server id.
  """
  def get_server(manager \\ @name, server_id) do
    GenServer.call(manager, {:get_server, server_id})
  end

  @doc """
  Returns map of active workers %{server_id => pid}.
  """
  def get_workers(manager \\ @name) do
    GenServer.call(manager, :get_workers)
  end

  @doc """
  Dynamically adds a server, starts a worker for it, and persists it to servers.yaml.
  """
  def add_server(server_or_map) do
    add_server(@name, server_or_map, [])
  end

  def add_server(manager, server_or_map) when is_pid(manager) or is_atom(manager) do
    add_server(manager, server_or_map, [])
  end

  def add_server(server_or_map, opts) when is_list(opts) do
    add_server(@name, server_or_map, opts)
  end

  def add_server(manager, server_or_map, opts) do
    GenServer.call(manager, {:add_server, server_or_map, opts})
  end

  @doc """
  Removes a server by ID, stops its worker, and updates servers.yaml.
  """
  def remove_server(server_id) do
    remove_server(@name, server_id)
  end

  def remove_server(manager, server_id) do
    GenServer.call(manager, {:remove_server, server_id})
  end

  @doc """
  Updates an existing server config and persists it without dropping the worker if possible.
  """
  def update_server(server_or_map) do
    GenServer.call(@name, {:update_server, server_or_map})
  end

  @doc """
  Duplicates a server entry with a new id.
  """
  def duplicate_server(server_id) do
    GenServer.call(@name, {:duplicate_server, to_string(server_id)})
  end

  @doc """
  Records last-connected time for a host.
  """
  def mark_connected(server_id) do
    GenServer.cast(@name, {:mark_connected, to_string(server_id)})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    config_path = Keyword.get(opts, :config_path)
    supervisor = Keyword.get(opts, :supervisor, ServerSupervisor)
    runner = Keyword.get(opts, :runner)
    poll_interval = Keyword.get(opts, :poll_interval, 5000)

    state = %__MODULE__{
      config_path: config_path,
      supervisor: supervisor,
      runner: runner,
      poll_interval: poll_interval,
      workers: %{}
    }

    if config_path && File.exists?(config_path) do
      {:ok, state, {:continue, {:sync_file, config_path}}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue({:sync_file, path}, state) do
    case do_sync_file(state, path, []) do
      {:ok, new_state, _result} -> {:noreply, new_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  @impl true
  def handle_call({:sync_config, config_or_servers, opts}, _from, state) do
    case do_sync_config(state, config_or_servers, opts) do
      {:ok, new_state, result} -> {:reply, {:ok, result}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:sync_file, path, opts}, _from, state) do
    case do_sync_file(state, path, opts) do
      {:ok, new_state, result} -> {:reply, {:ok, result}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:list_servers, _from, state) do
    servers =
      state.workers
      |> Enum.map(fn {id, pid} ->
        try do
          ServerWorker.get_state(pid, 1000)
        rescue
          _ -> %{id: id, name: id, host: id, status: :connecting, metrics: %{}, checks: %{}}
        catch
          :exit, _ ->
            %{id: id, name: id, host: id, status: :connecting, metrics: %{}, checks: %{}}
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:reply, servers, state}
  end

  @impl true
  def handle_call({:get_server, server_id}, _from, state) do
    case Map.get(state.workers, server_id) do
      pid when is_pid(pid) ->
        try do
          {:reply, {:ok, ServerWorker.get_state(pid, 1000)}, state}
        rescue
          _ -> {:reply, {:error, :worker_unavailable}, state}
        catch
          :exit, _ -> {:reply, {:error, :worker_unavailable}, state}
        end

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_workers, _from, state) do
    {:reply, state.workers, state}
  end

  @impl true
  def handle_call({:add_server, server_or_map, opts}, _from, state) do
    case parse_server_input(server_or_map) do
      {:ok, %Server{} = server} ->
        case do_add_server(state, server, opts) do
          {:ok, new_state, result} ->
            {:reply, {:ok, result}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_server, server_id}, _from, state) do
    case do_remove_server(state, to_string(server_id)) do
      {:ok, new_state, result} ->
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update_server, server_or_map}, _from, state) do
    path = state.config_path || Config.default_config_path()

    case parse_server_input(server_or_map) do
      {:ok, %Server{} = incoming} ->
        server = merge_existing_server(path, incoming)
        persist_server_addition(path, server)

        if pid = Map.get(state.workers, server.id) do
          try do
            SSHClient.ServerWorker.replace_config(pid, server)
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end
        end

        {:reply, {:ok, server.id}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:duplicate_server, server_id}, _from, state) do
    path = state.config_path || Config.default_config_path()

    case Config.load_file(path) do
      {:ok, %Config{servers: servers}} ->
        case Enum.find(servers, &(&1.id == server_id)) do
          nil ->
            {:reply, {:error, :not_found}, state}

          %Server{} = original ->
            copy = %{
              original
              | id: original.id <> "-copy",
                name: (original.name || original.id) <> " copy"
            }

            case do_add_server(state, copy, []) do
              {:ok, new_state, result} -> {:reply, {:ok, result}, new_state}
              {:error, reason} -> {:reply, {:error, reason}, state}
            end
        end

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:mark_connected, server_id}, state) do
    path = state.config_path || Config.default_config_path()
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Config.load_file(path) do
      {:ok, %Config{servers: servers}} ->
        updated =
          Enum.map(servers, fn s ->
            if s.id == server_id, do: %{s | last_connected_at: now}, else: s
          end)

        Config.save_file(updated, path)

        if pid = Map.get(state.workers, server_id) do
          try do
            SSHClient.ServerWorker.replace_config(
              pid,
              Enum.find(updated, &(&1.id == server_id))
            )
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  # Internal Logic

  defp do_sync_file(state, path, opts) do
    target_path = path || state.config_path || "servers.yaml"

    case Config.load_file(target_path) do
      {:ok, config} ->
        do_sync_config(%{state | config_path: target_path}, config, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_sync_config(state, %Config{servers: servers}, opts) do
    do_sync_servers(state, servers, opts)
  end

  defp do_sync_config(state, servers, opts) when is_list(servers) do
    do_sync_servers(state, servers, opts)
  end

  defp do_sync_config(_state, _invalid, _opts) do
    {:error, "invalid configuration target: expected %SSHClient.Config{} or list of servers"}
  end

  defp do_sync_servers(state, new_servers, opts) do
    target_servers = Map.new(new_servers, fn %Server{id: id} = s -> {id, s} end)
    current_ids = Map.keys(state.workers)
    target_ids = Map.keys(target_servers)

    ids_to_add = target_ids -- current_ids
    ids_to_remove = current_ids -- target_ids

    # 1. Stop removed servers
    updated_workers =
      Enum.reduce(ids_to_remove, state.workers, fn id, acc ->
        pid = Map.get(acc, id)
        ServerSupervisor.stop_worker(state.supervisor, pid)
        Map.delete(acc, id)
      end)

    # 2. Start new servers
    runner = Keyword.get(opts, :runner, state.runner)
    poll_interval = Keyword.get(opts, :poll_interval, state.poll_interval)

    worker_opts = [
      poll_interval: poll_interval
    ]

    worker_opts =
      if runner do
        Keyword.put(worker_opts, :runner, runner)
      else
        worker_opts
      end

    {final_workers, added_ids} =
      Enum.reduce(ids_to_add, {updated_workers, []}, fn id, {acc, added} ->
        server = Map.fetch!(target_servers, id)

        case ServerSupervisor.start_worker(state.supervisor, server, worker_opts) do
          {:ok, pid} ->
            {Map.put(acc, id, pid), [id | added]}

          {:error, {:already_started, pid}} ->
            {Map.put(acc, id, pid), added}

          _other ->
            {acc, added}
        end
      end)

    result = %{
      added: Enum.reverse(added_ids),
      removed: ids_to_remove,
      total_active: map_size(final_workers)
    }

    new_state =
      if runner do
        %{state | workers: final_workers, runner: runner}
      else
        %{state | workers: final_workers}
      end

    {:ok, new_state, result}
  end

  defp parse_server_input(%Server{} = s), do: {:ok, s}
  defp parse_server_input(attrs) when is_map(attrs), do: Server.from_map(attrs)
  defp parse_server_input(_other), do: {:error, "server must be a map or %Server{}"}

  defp do_add_server(state, %Server{} = server, opts) do
    # 1. Start worker
    runner = Keyword.get(opts, :runner, state.runner)
    poll_interval = Keyword.get(opts, :poll_interval, state.poll_interval)

    worker_opts = [poll_interval: poll_interval]
    worker_opts = if runner, do: Keyword.put(worker_opts, :runner, runner), else: worker_opts

    # If existing worker exists for this id, stop it first
    if existing_pid = Map.get(state.workers, server.id) do
      ServerSupervisor.stop_worker(state.supervisor, existing_pid)
    end

    case ServerSupervisor.start_worker(state.supervisor, server, worker_opts) do
      {:ok, pid} ->
        new_workers = Map.put(state.workers, server.id, pid)
        target_path = state.config_path || Config.default_config_path()

        # 2. Persist to servers.yaml
        persist_server_addition(target_path, server)

        result = %{
          id: server.id,
          name: server.name || server.id,
          host: server.host,
          port: server.port,
          status: "started"
        }

        {:ok, %{state | workers: new_workers, config_path: target_path}, result}

      {:error, reason} ->
        {:error, {:start_worker_failed, reason}}
    end
  end

  defp do_remove_server(state, server_id) do
    target_path = state.config_path || Config.default_config_path()
    pid = Map.get(state.workers, server_id)
    in_config? = server_in_config?(target_path, server_id)

    if pid do
      ServerSupervisor.stop_worker(state.supervisor, pid)
    end

    new_workers = Map.delete(state.workers, server_id)
    persist_server_removal(target_path, server_id)

    if pid != nil or in_config? do
      {:ok, %{state | workers: new_workers}, %{id: server_id, status: "removed"}}
    else
      {:error, :not_found}
    end
  end

  defp server_in_config?(path, server_id) do
    case Config.load_file(path) do
      {:ok, %Config{servers: servers}} ->
        Enum.any?(servers, fn s -> s.id == server_id end)

      _ ->
        false
    end
  end

  defp merge_existing_server(path, %Server{} = incoming) do
    case Config.load_file(path) do
      {:ok, %Config{servers: servers}} ->
        case Enum.find(servers, &(&1.id == incoming.id)) do
          nil ->
            incoming

          %Server{} = existing ->
            %{
              existing
              | name: incoming.name || existing.name,
                host: incoming.host || existing.host,
                user: incoming.user || existing.user,
                users: if(incoming.users in [nil, []], do: existing.users, else: incoming.users),
                port: incoming.port || existing.port,
                proxy_jump: incoming.proxy_jump || existing.proxy_jump,
                identity_file: incoming.identity_file || existing.identity_file,
                tags:
                  if(incoming.tags == [] and existing.tags != [],
                    do: existing.tags,
                    else: incoming.tags
                  ),
                notes:
                  if(incoming.notes in [nil, ""] and existing.notes not in [nil, ""],
                    do: existing.notes,
                    else: incoming.notes
                  ),
                favorite: incoming.favorite,
                last_connected_at: incoming.last_connected_at || existing.last_connected_at,
                auth_order: incoming.auth_order || existing.auth_order,
                default_auth_method: incoming.default_auth_method || existing.default_auth_method,
                checks: if(incoming.checks == [], do: existing.checks, else: incoming.checks)
            }
        end

      _ ->
        incoming
    end
  end

  defp persist_server_addition(path, %Server{} = server) do
    current_servers =
      case Config.load_file(path) do
        {:ok, %Config{servers: servers}} -> servers
        _ -> []
      end

    # Replace if same ID exists, or append
    updated_servers =
      if Enum.any?(current_servers, fn s -> s.id == server.id end) do
        Enum.map(current_servers, fn s ->
          if s.id == server.id, do: server, else: s
        end)
      else
        current_servers ++ [server]
      end

    Config.save_file(updated_servers, path)
  end

  defp persist_server_removal(path, server_id) do
    case Config.load_file(path) do
      {:ok, %Config{servers: servers}} ->
        filtered = Enum.reject(servers, fn s -> s.id == server_id end)
        Config.save_file(filtered, path)

      _ ->
        :ok
    end
  end
end
