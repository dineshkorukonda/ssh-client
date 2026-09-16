defmodule SSHClient.LauncherScriptTest do
  use ExUnit.Case, async: true

  @ps1 "priv/launch-gui.ps1"
  @bat "priv/launch-gui.bat"
  @vbs "priv/launch-gui.vbs"
  @installer "windows/installer.iss"
  @ci ".github/workflows/ci.yml"

  describe "powershell launcher" do
    test "script exists" do
      assert File.exists?(@ps1)
    end

    test "starts the OTP release with Start-Process Hidden instead of cmd start" do
      script = File.read!(@ps1)

      assert script =~ "Start-Process"
      assert script =~ "WindowStyle Hidden"
      assert script =~ "ssh_client.bat"
      refute script =~ ~r/cmd\.exe.*\sstart\s/i
      refute script =~ ~s[start "" ]
    end

    test "polls a vault-independent /health URL" do
      script = File.read!(@ps1)

      assert script =~ "/health"
      assert script =~ "127.0.0.1"
    end

    test "does not kill unrelated Erlang processes" do
      script = File.read!(@ps1)

      refute script =~ "taskkill /F /IM erl.exe"
      refute script =~ "taskkill /F /IM epmd.exe"
    end

    test "writes launcher logs under the user app data directory" do
      script = File.read!(@ps1)

      assert script =~ "APPDATA"
      assert script =~ "ssh-client"
      assert script =~ "logs"
      assert script =~ "launcher.log"
    end

    test "passes browser app flags as Start-Process arguments without nested cmd quotes" do
      script = File.read!(@ps1)

      assert script =~ "--app="
      assert script =~ "--user-data-dir"
      refute script =~ ~s[set "APP_FLAGS=]
      refute script =~ ~s[--user-data-dir="%]
    end

    test "does not pass a possibly empty ProgramFiles(x86) path to Join-Path" do
      script = File.read!(@ps1)

      assert script =~ ~s[GetEnvironmentVariable("ProgramFiles(x86)")]
      refute script =~ ~S[Join-Path ${env:ProgramFiles(x86)}]
    end
  end

  describe "vbs and bat wrappers" do
    test "vbs invokes the powershell launcher hidden" do
      script = File.read!(@vbs)

      assert script =~ "launch-gui.ps1"
      assert script =~ "powershell.exe"
      assert script =~ "-File"
    end

    test "bat delegates to the powershell launcher instead of starting the daemon itself" do
      script = File.read!(@bat)

      assert script =~ "launch-gui.ps1"
      refute script =~ "DAEMON_BAT"
      refute script =~ ~s[start "" /b]
      refute script =~ ~s[start "" "!DAEMON_BAT!"]
    end
  end

  describe "packaging" do
    test "windows installer bundles launch-gui.ps1" do
      script = File.read!(@installer)

      assert script =~ "launch-gui.ps1"
      assert script =~ "{app}\\bin"
    end

    test "windows packaging job copies launch-gui.ps1 into the release bin" do
      script = File.read!(@ci)

      assert script =~ "launch-gui.ps1"
      assert script =~ "rel\\ssh_client\\bin\\launch-gui.ps1"
    end
  end
end
