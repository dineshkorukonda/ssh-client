defmodule SSHClient.PersistenceFoundationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SSHClient.Repo
  alias SSHClient.TerminalWorkspace.LayoutNode
  alias SSHClient.TerminalWorkspace.Tab
  alias SSHClient.TerminalWorkspace.Workspace

  setup do
    assert Ecto.Adapters.SQL.Sandbox.checkout(Repo) in [:ok, {:already, :owner}]
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "application startup runs all workspace migrations" do
    tables =
      Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").rows
      |> List.flatten()

    assert "workspaces" in tables
    assert "terminal_tabs" in tables
    assert "layout_nodes" in tables
    assert "terminal_preferences" in tables
  end

  test "workspace rows persist when the repository connection restarts" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)

    workspace =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.insert!(struct(Workspace, name: "Persistent", position: 50))
      end)

    old_pid = Process.whereis(Repo)
    :ok = Repo.stop()
    assert eventually(fn -> repo_ready_after?(old_pid) end)
    assert Ecto.Adapters.SQL.Sandbox.checkout(Repo) in [:ok, {:already, :owner}]

    persisted = Repo.get!(Workspace, workspace.id)
    assert persisted.name == "Persistent"

    :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> Repo.delete!(persisted) end)
  end

  test "workspace and tab positions provide stable ordering" do
    later = Repo.insert!(struct(Workspace, name: "Later", position: 20))
    earlier = Repo.insert!(struct(Workspace, name: "Earlier", position: 10))

    Repo.insert!(
      struct(Tab,
        workspace_id: later.id,
        stable_id: "tab-later",
        title: "Later tab",
        position: 8
      )
    )

    Repo.insert!(
      struct(Tab,
        workspace_id: later.id,
        stable_id: "tab-earlier",
        title: "Earlier tab",
        position: 2
      )
    )

    workspace_ids = [earlier.id, later.id]

    assert Repo.all(
             from(workspace in Workspace,
               where: workspace.id in ^workspace_ids,
               order_by: workspace.position
             )
           )
           |> Enum.map(& &1.id) == [earlier.id, later.id]

    assert Repo.all(from(tab in Tab, order_by: tab.position))
           |> Enum.map(& &1.stable_id) == ["tab-earlier", "tab-later"]
  end

  test "deleting a workspace removes tabs and recursive layout nodes" do
    workspace = Repo.insert!(struct(Workspace, name: "Disposable", position: 100))

    tab =
      Repo.insert!(
        struct(Tab,
          workspace_id: workspace.id,
          stable_id: "tab-1",
          title: "Terminal",
          position: 0
        )
      )

    root =
      Repo.insert!(
        struct(LayoutNode,
          terminal_tab_id: tab.id,
          node_type: :split,
          position: 0,
          direction: :horizontal,
          ratio: 0.5
        )
      )

    Repo.insert!(
      struct(LayoutNode,
        terminal_tab_id: tab.id,
        parent_id: root.id,
        node_type: :pane,
        position: 0,
        pane_id: "pane-stable",
        host_id: "host-stable"
      )
    )

    Repo.delete!(workspace)

    assert Repo.aggregate(Tab, :count) == 0
    assert Repo.aggregate(LayoutNode, :count) == 0
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp repo_ready_after?(old_pid) do
    case Process.whereis(Repo) do
      pid when is_pid(pid) and pid != old_pid ->
        try do
          Repo.query!("SELECT 1")
          true
        rescue
          _ -> false
        catch
          :exit, _ -> false
        end

      _ ->
        false
    end
  end
end
