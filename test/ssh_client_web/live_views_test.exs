defmodule SSHClientWeb.LiveViewsTest do
  use ExUnit.Case, async: true

  test "live view modules compile and load successfully" do
    assert Code.ensure_loaded?(SSHClientWeb.HostLive)
    assert Code.ensure_loaded?(SSHClientWeb.TerminalLive)
    assert Code.ensure_loaded?(SSHClientWeb.SFTPLive)
    assert Code.ensure_loaded?(SSHClientWeb.SettingsLive)
    assert Code.ensure_loaded?(SSHClientWeb.LogsLive)
    assert Code.ensure_loaded?(SSHClientWeb.LockLive)
    assert Code.ensure_loaded?(SSHClientWeb.PageLive)
  end

  test "all live views export standard mount and render callbacks" do
    views = [
      SSHClientWeb.HostLive,
      SSHClientWeb.TerminalLive,
      SSHClientWeb.SFTPLive,
      SSHClientWeb.SettingsLive,
      SSHClientWeb.LogsLive,
      SSHClientWeb.LockLive,
      SSHClientWeb.PageLive
    ]

    for view <- views do
      assert function_exported?(view, :mount, 3)
      assert function_exported?(view, :render, 1)
    end
  end
end
