defmodule SSHClient.Store do
  @moduledoc """
  Atomic JSON document store for non-secret application data.
  Collections: workspaces, forwards, preferences, sessions.
  """

  use GenServer

  alias SSHClient.Config

  @name __MODULE__
  @collections [:workspaces, :forwards, :preferences, :sessions]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def default_path do
    Path.join(Config.os_config_dir(), "app-store.json")
  end

  def put(collection, id, value), do: put(@name, collection, id, value)

  def put(server, collection, id, value)
      when collection in @collections and is_binary(id) do
    GenServer.call(server, {:put, collection, id, value})
  end

  def get(collection, id), do: get(@name, collection, id)

  def get(server, collection, id) when collection in @collections do
    GenServer.call(server, {:get, collection, id})
  end

  def delete(collection, id), do: delete(@name, collection, id)

  def delete(server, collection, id) when collection in @collections do
    GenServer.call(server, {:delete, collection, id})
  end

  def list(collection), do: list(@name, collection)

  def list(server, collection) when collection in @collections do
    GenServer.call(server, {:list, collection})
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    data = load_file(path)
    {:ok, %{path: path, data: data}}
  end

  @impl true
  def handle_call({:put, collection, id, value}, _from, state) do
    col = Atom.to_string(collection)
    updated = put_in(state.data, [col, id], stringify_keys(value))

    case persist(state.path, updated) do
      :ok -> {:reply, :ok, %{state | data: updated}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, collection, id}, _from, state) do
    value = get_in(state.data, [Atom.to_string(collection), id])
    {:reply, value, state}
  end

  def handle_call({:delete, collection, id}, _from, state) do
    col = Atom.to_string(collection)
    updated = update_in(state.data, [col], fn map -> Map.delete(map || %{}, id) end)

    case persist(state.path, updated) do
      :ok -> {:reply, :ok, %{state | data: updated}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list, collection}, _from, state) do
    map = Map.get(state.data, Atom.to_string(collection), %{})
    list = map |> Map.values() |> Enum.sort_by(&Map.get(&1, "id", ""))
    {:reply, list, state}
  end

  defp load_file(path) do
    empty = %{
      "workspaces" => %{},
      "forwards" => %{},
      "preferences" => %{},
      "sessions" => %{}
    }

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) -> Map.merge(empty, map)
          _ -> empty
        end

      _ ->
        empty
    end
  end

  defp persist(path, data) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(data, pretty: true),
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other
end
