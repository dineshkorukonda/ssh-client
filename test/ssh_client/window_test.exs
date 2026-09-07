defmodule SSHClient.WindowTest do
  use ExUnit.Case, async: true

  test "child_spec returns valid worker specification with default options" do
    spec = SSHClient.Window.child_spec([])
    assert spec.id == SSHClient.Window
    assert spec.type == :worker
    assert spec.restart == :permanent
    assert spec.start == {SSHClient.Window, :start_link, [[]]}
  end

  test "child_spec returns valid worker specification with custom port" do
    spec = SSHClient.Window.child_spec(port: 4000)
    assert spec.id == SSHClient.Window
    assert spec.type == :worker
    assert spec.restart == :permanent
    assert spec.start == {SSHClient.Window, :start_link, [[port: 4000]]}
  end

  test "config resolves default parameters" do
    config = SSHClient.Window.config([])
    assert config.port == 4000
    assert config.url == "http://127.0.0.1:4000"
    assert config.title == "ssh-client"
    assert config.size == {1024, 720}
  end

  test "config resolves custom port in default url" do
    config = SSHClient.Window.config(port: 8080)
    assert config.port == 8080
    assert config.url == "http://127.0.0.1:8080"
  end

  test "config prioritizes explicit url over port" do
    config = SSHClient.Window.config(port: 8080, url: "http://custom-host:9000/hosts")
    assert config.url == "http://custom-host:9000/hosts"
  end

  test "config respects custom title and dimensions" do
    config = SSHClient.Window.config(title: "Custom Title", size: {1280, 800})
    assert config.title == "Custom Title"
    assert config.size == {1280, 800}
  end

  test "start_link starts fallback task in headless/test mode" do
    {:ok, pid} = SSHClient.Window.start_link(port: 4000)
    assert is_pid(pid)
    assert Process.alive?(pid)
    Process.exit(pid, :normal)
  end
end
