defmodule SSHClient.Store do
  @moduledoc "Local SQLite document store for hosts, workspaces, preferences and session metadata."
  use GenServer
  alias Exqlite.Sqlite3
  alias SSHClient.Config
  @collections [:hosts, :workspaces, :forwards, :preferences, :sessions]

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def default_path do
    System.get_env("SSH_CLIENT_APP_DATABASE_PATH") ||
      Path.join(
        if(System.get_env("SSH_CLIENT_DATABASE_PATH"),
          do: Path.dirname(System.get_env("SSH_CLIENT_DATABASE_PATH")),
          else: Config.os_config_dir()
        ),
        "app.sqlite3"
      )
  end

  def put(collection, id, value), do: put(__MODULE__, collection, id, value)

  def put(server, collection, id, value) when collection in @collections and is_binary(id),
    do: GenServer.call(server, {:put, collection, id, value})

  def get(collection, id), do: get(__MODULE__, collection, id)

  def get(server, collection, id) when collection in @collections,
    do: GenServer.call(server, {:get, collection, id})

  def delete(collection, id), do: delete(__MODULE__, collection, id)

  def delete(server, collection, id) when collection in @collections,
    do: GenServer.call(server, {:delete, collection, id})

  def list(collection), do: list(__MODULE__, collection)

  def list(server, collection) when collection in @collections,
    do: GenServer.call(server, {:list, collection})

  def import_hosts(path), do: GenServer.call(__MODULE__, {:import_hosts, path})
  def import_hosts(server, path), do: GenServer.call(server, {:import_hosts, path})
  def backup(path), do: GenServer.call(__MODULE__, {:backup, path}, 30_000)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())

    legacy =
      Keyword.get(
        opts,
        :legacy_path,
        if(Keyword.has_key?(opts, :path),
          do: nil,
          else: Path.join(Config.os_config_dir(), "app-store.json")
        )
      )

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, db} <- Sqlite3.open(path) do
      result =
        with :ok <-
               Sqlite3.execute(
                 db,
                 "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS documents (collection TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(collection,id)); CREATE TABLE IF NOT EXISTS imports (path TEXT PRIMARY KEY);"
               ),
             :ok <- import_legacy(db, legacy),
             do: :ok

      case result do
        :ok ->
          {:ok, %{db: db, path: path}}

        {:error, reason} ->
          Sqlite3.close(db)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_, state), do: Sqlite3.close(state.db)

  @impl true
  def handle_call({:put, collection, id, value}, _, state) do
    result =
      with {:ok, json} <- Jason.encode(value),
           {:ok, _} <-
             query(
               state.db,
               "INSERT INTO documents VALUES (?,?,?) ON CONFLICT(collection,id) DO UPDATE SET body=excluded.body",
               [to_string(collection), id, json]
             ),
           do: :ok

    {:reply, result, state}
  end

  def handle_call({:get, collection, id}, _, state) do
    result =
      case query(state.db, "SELECT body FROM documents WHERE collection=? AND id=?", [
             to_string(collection),
             id
           ]) do
        {:ok, [[body]]} -> Jason.decode!(body)
        {:ok, []} -> nil
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:list, collection}, _, state) do
    result =
      case query(state.db, "SELECT body FROM documents WHERE collection=? ORDER BY id", [
             to_string(collection)
           ]) do
        {:ok, rows} -> Enum.map(rows, fn [body] -> Jason.decode!(body) end)
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:delete, collection, id}, _, state) do
    result =
      with {:ok, _} <-
             query(state.db, "DELETE FROM documents WHERE collection=? AND id=?", [
               to_string(collection),
               id
             ]),
           do: :ok

    {:reply, result, state}
  end

  def handle_call({:import_hosts, path}, _, state) do
    result =
      import_once(state.db, path, fn ->
        with {:ok, config} <- Config.load_file(path) do
          {:ok,
           Enum.map(config.servers, fn server -> {:hosts, server.id, host_document(server)} end)}
        end
      end)

    {:reply, result, state}
  end

  def handle_call({:backup, path}, _, state) do
    result = with {:ok, _} <- query(state.db, "VACUUM INTO ?", [path]), do: :ok
    {:reply, result, state}
  end

  def host_document(server),
    do:
      Map.from_struct(server)
      |> Map.update!(:checks, fn checks -> Enum.map(checks, &Map.from_struct/1) end)

  defp import_legacy(_, nil), do: :ok

  defp import_legacy(db, path) do
    import_once(db, path, fn ->
      with {:ok, content} <- File.read(path),
           {:ok, data} when is_map(data) <- Jason.decode(content),
           true <- Enum.all?(@collections, &is_map(Map.get(data, to_string(&1), %{}))) do
        records =
          for collection <- @collections,
              {id, value} <- Map.get(data, to_string(collection), %{}),
              do: {collection, id, value}

        {:ok, records}
      else
        _ -> {:error, :invalid_legacy_store}
      end
    end)
  end

  defp import_once(db, path, loader) do
    if File.exists?(path) do
      with {:ok, imported} <-
             query(db, "SELECT path FROM imports WHERE path=?", [Path.expand(path)]) do
        if imported == [] do
          with {:ok, records} <- loader.(), :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
            result =
              Enum.reduce_while(records, :ok, fn {collection, id, value}, :ok ->
                with {:ok, json} <- Jason.encode(value),
                     {:ok, _} <-
                       query(db, "INSERT OR IGNORE INTO documents VALUES (?,?,?)", [
                         to_string(collection),
                         id,
                         json
                       ]) do
                  {:cont, :ok}
                else
                  error -> {:halt, error}
                end
              end)

            result =
              with :ok <- result,
                   {:ok, _} <- query(db, "INSERT INTO imports VALUES (?)", [Path.expand(path)]),
                   do: :ok

            case result do
              :ok ->
                Sqlite3.execute(db, "COMMIT")

              error ->
                Sqlite3.execute(db, "ROLLBACK")
                error
            end
          end
        else
          :ok
        end
      end
    else
      :ok
    end
  end

  defp query(db, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params), do: rows(db, statement, [])
      after
        Sqlite3.release(db, statement)
      end
    end
  end

  defp rows(db, statement, acc) do
    case Sqlite3.step(db, statement) do
      {:row, row} -> rows(db, statement, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
