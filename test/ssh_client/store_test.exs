defmodule SSHClient.StoreTest do
  use ExUnit.Case, async: true

  alias SSHClient.Store

  setup do
    path = Path.join(System.tmp_dir!(), "store-test-#{System.unique_integer([:positive])}.json")
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

  test "survives reload from disk", %{store: store, path: path} do
    assert :ok = Store.put(store, :sessions, "host-a", %{id: "host-a", pane_ids: ["s1"]})
    {:ok, store2} = start_supervised({Store, name: nil, path: path}, id: :store_reload)
    assert %{"id" => "host-a", "pane_ids" => ["s1"]} = Store.get(store2, :sessions, "host-a")
  end
end
