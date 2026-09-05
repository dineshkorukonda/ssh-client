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
    assert elem(sftp_route.metadata.phoenix_live_view, 0) == SSHClientWeb.SFTPLive
    assert elem(sftp_route.metadata.phoenix_live_view, 1) == :show

    terminal_route = Enum.find(routes, &(&1.path == "/terminal/:id"))
    assert elem(terminal_route.metadata.phoenix_live_view, 0) == SSHClientWeb.TerminalLive
    assert elem(terminal_route.metadata.phoenix_live_view, 1) == :show

    hosts_route = Enum.find(routes, &(&1.path == "/hosts"))
    assert elem(hosts_route.metadata.phoenix_live_view, 0) == SSHClientWeb.HostLive
    assert elem(hosts_route.metadata.phoenix_live_view, 1) == :index

    settings_route = Enum.find(routes, &(&1.path == "/settings"))
    assert elem(settings_route.metadata.phoenix_live_view, 0) == SSHClientWeb.SettingsLive
    assert elem(settings_route.metadata.phoenix_live_view, 1) == :index

    logs_route = Enum.find(routes, &(&1.path == "/logs"))
    assert elem(logs_route.metadata.phoenix_live_view, 0) == SSHClientWeb.LogsLive
    assert elem(logs_route.metadata.phoenix_live_view, 1) == :index

    lock_route = Enum.find(routes, &(&1.path == "/lock"))
    assert elem(lock_route.metadata.phoenix_live_view, 0) == SSHClientWeb.LockLive
    assert elem(lock_route.metadata.phoenix_live_view, 1) == :index
  end
end
