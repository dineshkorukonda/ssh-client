defmodule SSHClientWeb.SettingsLiveTest do
  use ExUnit.Case, async: true

  alias SSHClientWeb.SettingsLive

  test "module defines valid mount and event handlers" do
    assert Code.ensure_loaded?(SettingsLive)
    assert function_exported?(SettingsLive, :mount, 3)
    assert function_exported?(SettingsLive, :handle_event, 3)
  end
end
