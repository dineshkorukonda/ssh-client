defmodule SSHClient.WorkspaceTest do
  use ExUnit.Case, async: false

  alias SSHClient.Workspace

  test "create list get add_host and delete" do
    name = "ws-test-#{System.unique_integer([:positive])}"
    assert {:ok, record} = Workspace.create(name, ["host-a", "host-b"])
    id = record["id"]

    assert Workspace.get(id)["name"] == name
    assert "host-a" in Workspace.get(id)["server_ids"]
    assert Enum.any?(Workspace.list(), &(&1["id"] == id))

    assert :ok = Workspace.add_host(id, "host-c")
    assert "host-c" in Workspace.get(id)["server_ids"]

    assert :ok = Workspace.delete(id)
    assert Workspace.get(id) == nil
  end

  test "add_host on missing workspace returns not_found" do
    assert {:error, :not_found} = Workspace.add_host("missing-id", "host-a")
  end
end
