defmodule SSHClient.UpdaterTest do
  use ExUnit.Case, async: true

  alias SSHClient.Updater

  describe "current_version/0" do
    test "returns current semver version" do
      version = Updater.current_version()
      assert is_binary(version)
      assert version =~ ~r/^[0-9]+\.[0-9]+\.[0-9]+/
    end
  end

  describe "version_greater?/2" do
    test "correctly compares semantic versions" do
      assert Updater.version_greater?("0.0.2", "0.0.1") == true
      assert Updater.version_greater?("v0.0.2", "v0.0.1") == true
      assert Updater.version_greater?("1.0.0", "0.0.1") == true
      assert Updater.version_greater?("0.0.1", "0.0.1") == false
      assert Updater.version_greater?("0.0.1", "0.0.2") == false
    end
  end

  describe "detect_os/0" do
    test "returns atom indicating valid OS" do
      assert Updater.detect_os() in [:windows, :linux, :macos, :other]
    end
  end

  describe "staging_dir/0" do
    test "returns valid path" do
      path = Updater.staging_dir()
      assert is_binary(path)
      assert String.ends_with?(path, "staging")
    end
  end

  describe "app_root_dir/0" do
    test "returns valid application root directory" do
      path = Updater.app_root_dir()
      assert is_binary(path)
      assert File.exists?(path)
    end
  end

  describe "select_platform_asset/2" do
    test "selects windows zip archive for windows platform" do
      assets = [
        %{name: "ssh-client-linux-x64.tar.gz", browser_download_url: "https://example.com/linux"},
        %{name: "ssh-client-setup-v0.0.1-windows-x64.exe", browser_download_url: "https://example.com/win_exe"},
        %{name: "ssh-client-windows-x64.zip", browser_download_url: "https://example.com/win_zip"}
      ]

      asset = Updater.select_platform_asset(assets, :windows)
      assert asset.name =~ ".zip"
    end

    test "selects tarball for linux platform" do
      assets = [
        %{name: "ssh-client-setup-v0.0.1-windows-x64.exe", browser_download_url: "https://example.com/win_exe"},
        %{name: "ssh-client-linux-x64.tar.gz", browser_download_url: "https://example.com/linux"}
      ]

      asset = Updater.select_platform_asset(assets, :linux)
      assert asset.name =~ ".tar.gz"
    end
  end

  describe "build_windows_update_script/4" do
    test "generates robust script with tree kill, logging, and non-interactive delay" do
      script = Updater.build_windows_update_script("C:\\staging", "C:\\app", "C:\\staging\\update.log", 1234)

      # 1. Non-interactive delay (no timeout command)
      refute script =~ "timeout "
      assert script =~ "ping -n 3 127.0.0.1"

      # 2. Forceful tree termination of Erlang and epmd daemons
      assert script =~ "taskkill /F /T /PID 1234"
      assert script =~ "taskkill /F /T /IM erl.exe"
      assert script =~ "taskkill /F /T /IM epmd.exe"
      assert script =~ "taskkill /F /T /IM werl.exe"
      assert script =~ "taskkill /F /T /IM beam.smp"

      # 3. Non-destructive verified copy
      assert script =~ "robocopy"
      assert script =~ "/E /IS /IT"
      refute script =~ "/MOVE"

      # 4. Diagnostics logging
      assert script =~ "update.log"

      # 5. Clean relaunch
      assert script =~ "launch-gui.vbs"
    end
  end

  describe "build_linux_update_script/3" do
    test "generates shell script with start command" do
      script = Updater.build_linux_update_script("/tmp/staging", "/opt/ssh-client", 5678)

      assert script =~ "#!/bin/sh"
      assert script =~ "kill -9 5678"
      assert script =~ "/opt/ssh-client/bin/ssh_client\" start &"
      refute script =~ "daemon &"
    end
  end
end
