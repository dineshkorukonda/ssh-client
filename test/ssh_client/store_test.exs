defmodule SSHClient.StoreTest do
  use ExUnit.Case, async: true

  alias SSHClient.Store

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "store-test-#{System.os_time(:microsecond)}-#{System.unique_integer([:positive])}.sqlite3"
      )

    {:ok, pid} = start_supervised({Store, name: nil, path: path})
    on_exit(fn -> File.rm(path) end)
    %{store: pid, path: path}
  end

  test "put get list delete round trip", %{store: store, path: path} do
    assert :ok = Store.put(store, :workspaces, "ws-1", %{id: "ws-1", name: "Lab"})
    assert %{"id" => "ws-1", "name" => "Lab"} = Store.get(store, :workspaces, "ws-1")
    assert [%{"id" => "ws-1"}] = Store.list(store, :workspaces)
    assert File.exists?(path)

    assert :ok = Store.delete(store, :workspaces, "ws-1")
    assert Store.get(store, :workspaces, "ws-1") == nil
    assert Store.list(store, :workspaces) == []
  end

  test "rejects malformed legacy collections without rewriting the source", %{path: path} do
    legacy = path <> ".invalid.json"
    content = Jason.encode!(%{preferences: nil})
    File.write!(legacy, content)
    on_exit(fn -> File.rm(legacy) end)

    assert {:stop, :invalid_legacy_store} = Store.init(path: path, legacy_path: legacy)

    assert File.read!(legacy) == content
  end

  test "survives reload from disk", %{store: store, path: path} do
    assert :ok = Store.put(store, :sessions, "host-a", %{id: "host-a", pane_ids: ["s1"]})
    {:ok, store2} = start_supervised({Store, name: nil, path: path}, id: :store_reload)
    assert %{"id" => "host-a", "pane_ids" => ["s1"]} = Store.get(store2, :sessions, "host-a")
  end

  test "imports legacy host metadata once and never resurrects a deleted host", %{
    store: store,
    path: path
  } do
    legacy = path <> ".json"
    on_exit(fn -> File.rm(legacy) end)

    File.write!(
      legacy,
      Jason.encode!(%{
        servers: [
          %{
            id: "imported",
            name: "Imported",
            host: "localhost",
            user: "fixture",
            tags: ["lab"],
            favorite: true
          }
        ]
      })
    )

    assert :ok = Store.import_hosts(store, legacy)
    assert %{"favorite" => true, "tags" => ["lab"]} = Store.get(store, :hosts, "imported")
    assert :ok = Store.delete(store, :hosts, "imported")
    assert :ok = Store.import_hosts(store, legacy)
    assert Store.get(store, :hosts, "imported") == nil
    assert File.exists?(legacy)
  end

  test "imports JSON preferences and workspaces without replacing SQLite edits", %{path: path} do
    legacy = path <> ".legacy.json"
    on_exit(fn -> File.rm(legacy) end)

    File.write!(
      legacy,
      Jason.encode!(%{
        workspaces: %{old: %{id: "old", name: "Legacy", server_ids: ["host-a"]}},
        preferences: %{theme: %{id: "theme", font_size: 15}}
      })
    )

    {:ok, migrated} =
      start_supervised({Store, name: nil, path: path, legacy_path: legacy}, id: :migration)

    assert %{"server_ids" => ["host-a"]} = Store.get(migrated, :workspaces, "old")
    assert :ok = Store.put(migrated, :preferences, "theme", %{id: "theme", font_size: 18})

    {:ok, reloaded} =
      start_supervised({Store, name: nil, path: path, legacy_path: legacy}, id: :migration_reload)

    assert %{"font_size" => 18} = Store.get(reloaded, :preferences, "theme")
    assert File.read!(path) =~ "SQLite format 3"
  end
end
