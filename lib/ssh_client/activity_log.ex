defmodule SSHClient.ActivityLog do
  @moduledoc """
  Centralized activity and diagnostic logger storing an in-memory ring buffer of
  recent SSH connection events, worker state changes, and system errors.

  Supports querying by severity level and server ID, and broadcasts events
  over Phoenix.PubSub (or local subscribers) for live UI updates.
  """

  use GenServer

  @name __MODULE__
  @max_entries 500

  defstruct entries: [],
            max_entries: @max_entries,
            subscribers: []

  @type level :: :info | :warn | :error

  @type log_entry :: %{
          id: String.t(),
          timestamp: DateTime.t(),
          level: level(),
          server_id: String.t() | nil,
          message: String.t(),
          details: String.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Appends a new log entry.
  """
  def log(level, server_id, message, details \\ nil) do
    if Process.whereis(@name) do
      GenServer.cast(@name, {:log, level, server_id, message, details})
    else
      :ok
    end
  end

  def info(server_id, message, details \\ nil), do: log(:info, server_id, message, details)
  def warn(server_id, message, details \\ nil), do: log(:warn, server_id, message, details)
  def error(server_id, message, details \\ nil), do: log(:error, server_id, message, details)

  @doc """
  Returns all stored log entries, newest first.
  Options:
    - `:limit` (integer): maximum number of entries to return (default: 100)
    - `:level` (atom): filter by level (:info, :warn, :error)
    - `:server_id` (string): filter by server ID
  """
  def list_logs(opts \\ []) do
    if Process.whereis(@name) do
      GenServer.call(@name, {:list_logs, opts})
    else
      []
    end
  end

  @doc """
  Clears all stored log entries.
  """
  def clear do
    if Process.whereis(@name) do
      GenServer.call(@name, :clear)
    else
      :ok
    end
  end

  @doc """
  Subscribes the calling process to receive `{:new_log_entry, entry}` messages.
  """
  def subscribe do
    if Process.whereis(@name) do
      GenServer.call(@name, {:subscribe, self()})
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    max_entries = Keyword.get(opts, :max_entries, @max_entries)
    {:ok, %__MODULE__{max_entries: max_entries, entries: [], subscribers: []}}
  end

  @impl true
  def handle_cast({:log, level, server_id, message, details}, state) do
    entry = %{
      id: "log_#{System.unique_integer([:positive, :monotonic])}",
      timestamp: DateTime.utc_now(),
      level: level,
      server_id: server_id && to_string(server_id),
      message: to_string(message),
      details: format_details(details)
    }

    # Broadcast to local subscribers
    Enum.each(state.subscribers, fn pid ->
      if Process.alive?(pid) do
        send(pid, {:new_log_entry, entry})
      end
    end)

    new_entries = [entry | Enum.take(state.entries, state.max_entries - 1)]
    {:noreply, %{state | entries: new_entries}}
  end

  @impl true
  def handle_call({:list_logs, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    filter_level = Keyword.get(opts, :level)
    filter_server = Keyword.get(opts, :server_id)

    filtered =
      state.entries
      |> Enum.filter(fn entry ->
        match_level?(entry.level, filter_level) and
          match_server?(entry.server_id, filter_server)
      end)
      |> Enum.take(limit)

    {:reply, filtered, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: []}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    subs = Enum.uniq([pid | state.subscribers])
    {:reply, :ok, %{state | subscribers: subs}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp match_level?(_entry_level, nil), do: true
  defp match_level?(_entry_level, :all), do: true
  defp match_level?(_entry_level, "all"), do: true
  defp match_level?(entry_level, level) when is_atom(level), do: entry_level == level

  defp match_level?(entry_level, level) when is_binary(level),
    do: Atom.to_string(entry_level) == level

  defp match_server?(_entry_server, nil), do: true
  defp match_server?(_entry_server, ""), do: true
  defp match_server?(_entry_server, "all"), do: true
  defp match_server?(entry_server, server) when is_binary(server), do: entry_server == server

  defp format_details(nil), do: nil
  defp format_details(str) when is_binary(str), do: str
  defp format_details(term), do: inspect(term, pretty: true, limit: 200)
end
