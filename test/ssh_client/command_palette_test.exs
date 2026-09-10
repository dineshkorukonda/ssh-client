defmodule SSHClient.CommandPaletteTest do
  use ExUnit.Case, async: true

  alias SSHClient.CommandPalette

  test "lists core actions" do
    ids = Enum.map(CommandPalette.actions(), & &1.id)
    assert "new_tab" in ids
    assert "split_right" in ids
    assert "reconnect" in ids
    assert "open_sftp" in ids
  end

  test "filters hosts and actions by query" do
    servers = [%{id: "api", name: "API Prod", host: "10.0.0.8", user: "deploy"}]
    items = CommandPalette.items(servers, "api")
    assert Enum.any?(items, &(&1.id == "connect:api"))
    refute Enum.any?(items, &(&1.id == "settings"))
  end
end
