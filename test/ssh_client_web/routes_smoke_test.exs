defmodule SSHClientWeb.RoutesSmokeTest do
  use ExUnit.Case, async: true

  alias SSHClientWeb.Router

  test "router is loaded and compiled" do
    assert Code.ensure_loaded?(Router)
  end

  test "router defines all top-level application routes" do
    routes = Router.__routes__()

    paths = Enum.map(routes, & &1.path)

    assert "/" in paths
    assert "/hosts" in paths
    assert "/lock" in paths
    assert "/terminal/:id" in paths
    assert "/sftp/:id" in paths
    assert "/settings" in paths
    assert "/logs" in paths
  end

  test "route plugs map directly to expected LiveView modules" do
    routes = Router.__routes__()

    sftp_route = Enum.find(routes, &(&1.path == "/sftp/:id"))
    assert sftp_route.plug == SSHClientWeb.SFTPLive
    assert sftp_route.plug_opts == :show

    terminal_route = Enum.find(routes, &(&1.path == "/terminal/:id"))
    assert terminal_route.plug == SSHClientWeb.TerminalLive
    assert terminal_route.plug_opts == :show

    hosts_route = Enum.find(routes, &(&1.path == "/hosts"))
    assert hosts_route.plug == SSHClientWeb.HostLive
    assert hosts_route.plug_opts == :index

    settings_route = Enum.find(routes, &(&1.path == "/settings"))
    assert settings_route.plug == SSHClientWeb.SettingsLive
    assert settings_route.plug_opts == :index

    logs_route = Enum.find(routes, &(&1.path == "/logs"))
    assert logs_route.plug == SSHClientWeb.LogsLive
    assert logs_route.plug_opts == :index

    lock_route = Enum.find(routes, &(&1.path == "/lock"))
    assert lock_route.plug == SSHClientWeb.LockLive
    assert lock_route.plug_opts == :index
  end
end
