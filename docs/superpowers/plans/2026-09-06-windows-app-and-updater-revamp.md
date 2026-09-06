# Windows Host Lifecycle, Robust Auto-Updater & Quality Revamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a robust, reliable auto-updater, eliminate runtime crashes on `/settings`, harden production security (127.0.0.1 binding), and provide a dedicated native Windows desktop shell with clean lifecycle daemon termination on window close.

**Architecture:** Update `SSHClient.Updater` with non-interactive delay and forceful Erlang/epmd tree kill; update `priv/launch-gui.bat` to poll backend health and cleanly terminate the daemon when the window closes; restore missing `Auth` alias in `SettingsLive`; style `ErrorHTML` with a dark editorial shell; bind Bandit to localhost in `prod.exs`.

**Tech Stack:** Elixir 1.18+, Phoenix LiveView 1.0+, Windows Batch & PowerShell, Erlang OTP 27, Inno Setup 6.

**Spec:** `docs/superpowers/specs/2026-09-06-windows-app-and-updater-revamp-design.md`

## Global Constraints

- Strict zero-emoji policy across all files, code, templates, and commit messages (enforced by `scripts/sync_release.py --emoji-check`).
- Adhere to the editorial stark dark aesthetic (monochrome #050505, high-contrast typography, red/blue accents).
- Keep versioning and release sync intact (verified by `scripts/sync_release.py --check`).
- Small, focused edits with defensive error handling and pattern matching.

---

### Task 1: Fix SettingsLive Crash & Style Editorial ErrorHTML

**Files:**
- Modify: `lib/ssh_client_web/live/settings_live.ex:1-35`
- Modify: `lib/ssh_client_web/controllers/error_html.ex:1-16`
- Create: `test/ssh_client_web/settings_live_test.exs`
- Create: `test/ssh_client_web/error_html_test.exs`

**Interfaces:**
- Consumes: `SSHClient.SSH.Auth.resolve_identities/1`, `SSHClient.Vault.unlocked?/0`
- Produces: Working `/settings` mount and dark-styled 404/500 HTML error views.

- [ ] **Step 1: Write tests for SettingsLive mount and ErrorHTML rendering**

Create `test/ssh_client_web/error_html_test.exs`:
```elixir
defmodule SSHClientWeb.ErrorHTMLTest do
  use ExUnit.Case, async: true

  alias SSHClientWeb.ErrorHTML

  test "renders 500.html with dark theme and proper document title" do
    rendered = ErrorHTML.render("500.html", %{}) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    assert rendered =~ "500"
    assert rendered =~ "Internal Server Error"
    assert rendered =~ "background:#050505" or rendered =~ "bg-[#050505]"
    assert rendered =~ "Return to Servers"
  end

  test "renders 404.html with dark theme" do
    rendered = ErrorHTML.render("404.html", %{}) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    assert rendered =~ "404"
    assert rendered =~ "Page Not Found"
  end
end
```

Create `test/ssh_client_web/settings_live_test.exs`:
```elixir
defmodule SSHClientWeb.SettingsLiveTest do
  use ExUnit.Case, async: true

  alias SSHClientWeb.SettingsLive

  test "module defines valid mount and event handlers" do
    assert Code.ensure_loaded?(SettingsLive)
    assert function_exported?(SettingsLive, :mount, 3)
    assert function_exported?(SettingsLive, :handle_event, 3)
  end
end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `python scripts/sync_release.py --emoji-check`

- [ ] **Step 3: Implement alias in SettingsLive and dark template in ErrorHTML**

In `lib/ssh_client_web/live/settings_live.ex`:
```elixir
  alias SSHClient.Config
  alias SSHClient.ServerManager
  alias SSHClient.SSH.Auth
  alias SSHClient.SSH.ConfigImporter
  alias SSHClient.SSH.HostKeyVerifier
  alias SSHClient.Updater
  alias SSHClient.Vault
```

In `lib/ssh_client_web/controllers/error_html.ex`:
```elixir
defmodule SSHClientWeb.ErrorHTML do
  use Phoenix.Component

  def render("404.html", _assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <title>404 - Page Not Found</title>
        <style>
          body { margin: 0; background: #050505; color: #e4e4e7; font-family: monospace; display: flex; align-items: center; justify-content: center; height: 100vh; text-align: center; }
          a { color: #38bdf8; text-decoration: none; border: 1px solid #27272a; padding: 8px 16px; border-radius: 8px; margin-top: 16px; display: inline-block; }
          a:hover { background: #18181b; }
        </style>
      </head>
      <body>
        <div>
          <h1 style="font-size: 3rem; margin: 0; color: #ef4444;">404</h1>
          <p style="color: #71717a; margin-top: 8px;">Page Not Found</p>
          <a href="/hosts">Return to Servers</a>
        </div>
      </body>
    </html>
    """
  end

  def render("500.html", _assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <title>500 - Internal Server Error</title>
        <style>
          body { margin: 0; background: #050505; color: #e4e4e7; font-family: monospace; display: flex; align-items: center; justify-content: center; height: 100vh; text-align: center; }
          a { color: #38bdf8; text-decoration: none; border: 1px solid #27272a; padding: 8px 16px; border-radius: 8px; margin-top: 16px; display: inline-block; }
          a:hover { background: #18181b; }
        </style>
      </head>
      <body>
        <div>
          <h1 style="font-size: 3rem; margin: 0; color: #ef4444;">500</h1>
          <p style="color: #71717a; margin-top: 8px;">Internal Server Error</p>
          <a href="/hosts">Return to Servers</a>
        </div>
      </body>
    </html>
    """
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
```

- [ ] **Step 4: Verify aesthetic rules and run tests**

Run: `python scripts/sync_release.py --emoji-check`

- [ ] **Step 5: Commit**

```bash
git add lib/ssh_client_web/live/settings_live.ex lib/ssh_client_web/controllers/error_html.ex test/ssh_client_web/
git commit -m "fix(liveview): restore Auth alias in SettingsLive and style dark ErrorHTML"
```

---

### Task 2: Production Security Hardening

**Files:**
- Modify: `config/prod.exs`

**Interfaces:**
- Consumes: Bandit PhoenixAdapter config
- Produces: Localhost-only HTTP listener in production

- [ ] **Step 1: Inspect config/prod.exs**

- [ ] **Step 2: Update config/prod.exs to restrict IP to 127.0.0.1**

In `config/prod.exs`:
```elixir
import Config

config :ssh_client, SSHClientWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: System.get_env("SECRET_KEY_BASE") ||
    "sshclientprodkeybase000000000000000000000000000000000000000000000",
  live_view: [signing_salt: "sshclientlv"],
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :logger, level: :warning
```

- [ ] **Step 3: Commit**

```bash
git add config/prod.exs
git commit -m "security: restrict Bandit listener to localhost in production"
```

---

### Task 3: Robust In-Place Updater (Windows & Linux)

**Files:**
- Modify: `lib/ssh_client/updater.ex:250-350`
- Modify: `test/ssh_client/updater_test.exs`

**Interfaces:**
- Consumes: `apply_update_windows/3`, `apply_update_linux/3`
- Produces: Non-blocking, locked-process-killing detached updater with error logging to `update.log`.

- [ ] **Step 1: Write unit tests for update script content**

In `test/ssh_client/updater_test.exs`, add assertions verifying:
- `apply_update.bat` contains `ping -n 3 127.0.0.1` (not `timeout`).
- `apply_update.bat` contains `taskkill /F /T /IM erl.exe` and `taskkill /F /T /IM epmd.exe`.
- `apply_update.bat` redirects to `update.log`.
- `apply_update.sh` invokes `ssh_client start` (not `ssh_client daemon`).

- [ ] **Step 2: Update updater.ex with robust batch script generation**

In `lib/ssh_client/updater.ex`:
```elixir
  defp apply_update_windows(staged_dir, target_dir, current_pid) do
    script_dir = staging_dir()
    File.mkdir_p!(script_dir)
    bat_path = Path.join(script_dir, "apply_update.bat")
    vbs_path = Path.join(script_dir, "apply_update.vbs")
    log_path = Path.join(script_dir, "update.log")

    win_staged = String.replace(staged_dir, "/", "\\")
    win_target = String.replace(target_dir, "/", "\\")
    win_log = String.replace(log_path, "/", "\\")

    bat_content = """
    @echo off
    setlocal enabledelayedexpansion

    echo === ssh-client update started: %date% %time% === > "#{win_log}"

    :: 1. Pause cleanly without using non-interactive timeout command
    ping -n 3 127.0.0.1 >nul 2>&1

    :: 2. Forcefully terminate running instances and child daemons to release file locks
    if not "#{current_pid}"=="" (
        taskkill /F /T /PID #{current_pid} >> "#{win_log}" 2>&1
    )
    taskkill /F /T /IM erl.exe >> "#{win_log}" 2>&1
    taskkill /F /T /IM epmd.exe >> "#{win_log}" 2>&1
    taskkill /F /T /IM werl.exe >> "#{win_log}" 2>&1
    taskkill /F /T /IM beam.smp >> "#{win_log}" 2>&1

    :: Extra pause to allow OS file handles to close
    ping -n 2 127.0.0.1 >nul 2>&1

    :: 3. Copy staged release files into application directory (non-destructive)
    echo Copying files from "#{win_staged}" to "#{win_target}"... >> "#{win_log}"
    robocopy "#{win_staged}" "#{win_target}" /E /IS /IT /R:5 /W:1 >> "#{win_log}" 2>&1
    if errorlevel 8 (
        echo Robocopy reported errors, falling back to xcopy... >> "#{win_log}"
        xcopy "#{win_staged}\\*" "#{win_target}\\" /E /Y /I /Q >> "#{win_log}" 2>&1
    )

    :: 4. Clean up staging folder
    rmdir /S /Q "#{win_staged}" >> "#{win_log}" 2>&1

    :: 5. Relaunch ssh-client
    echo Relaunching application... >> "#{win_log}"
    if exist "#{win_target}\\bin\\launch-gui.vbs" (
        start "" wscript.exe "#{win_target}\\bin\\launch-gui.vbs"
    ) else if exist "#{win_target}\\bin\\launch-gui.bat" (
        start "" "#{win_target}\\bin\\launch-gui.bat"
    ) else if exist "#{win_target}\\bin\\ssh_client.bat" (
        start "" "#{win_target}\\bin\\ssh_client.bat" start
    )

    echo === Update completed successfully === >> "#{win_log}"
    exit /b 0
    """

    vbs_content = """
    Set WshShell = CreateObject("WScript.Shell")
    WshShell.Run "cmd /c """ & WScript.Arguments(0) & """", 0, False
    """

    File.write!(bat_path, bat_content)
    File.write!(vbs_path, vbs_content)

    try do
      System.cmd("wscript.exe", [vbs_path, bat_path], spawn_opt: [:detached])
    rescue
      _ ->
        System.cmd("cmd.exe", ["/c", "start", "", "/b", bat_path], spawn_opt: [:detached])
    end

    schedule_vm_shutdown()

    {:ok, :restarting, "Update script launched. ssh-client is restarting into the new version."}
  end

  defp apply_update_linux(staged_dir, target_dir, current_pid) do
    script_dir = staging_dir()
    File.mkdir_p!(script_dir)
    sh_path = Path.join(script_dir, "apply_update.sh")

    sh_content = """
    #!/bin/sh
    sleep 1
    if [ -n "#{current_pid}" ]; then
        kill -9 #{current_pid} 2>/dev/null || true
    fi

    cp -rf "#{staged_dir}"/* "#{target_dir}"/
    rm -rf "#{staged_dir}"

    if [ -f "#{target_dir}/bin/ssh_client" ]; then
        "#{target_dir}/bin/ssh_client" start &
    fi
    """

    File.write!(sh_path, sh_content)
    File.chmod!(sh_path, 0o755)

    try do
      System.cmd("sh", [sh_path], spawn_opt: [:detached])
    rescue
      _ -> :ok
    end

    schedule_vm_shutdown()

    {:ok, :restarting, "Update script launched. ssh-client is restarting into the new version."}
  end
```

- [ ] **Step 3: Verify with sync_release and emoji check**

Run: `python scripts/sync_release.py --emoji-check`

- [ ] **Step 4: Commit**

```bash
git add lib/ssh_client/updater.ex test/ssh_client/updater_test.exs
git commit -m "fix(updater): eliminate process lock failures and add update logging"
```

---

### Task 4: Dedicated Native Windows Shell & Lifecycle Controller

**Files:**
- Modify: `priv/launch-gui.bat`
- Modify: `priv/launch-gui.vbs`

**Interfaces:**
- Consumes: `ssh_client.bat start`, `ssh_client.bat stop`
- Produces: Pre-flight health-checked, isolated profile GUI launcher that cleans up daemons on exit.

- [ ] **Step 1: Update priv/launch-gui.bat**

Implement:
1. Health check: start daemon if not listening on port 4000.
2. Wait loop: poll `http://127.0.0.1:4000/` using PowerShell.
3. Isolated profile window: `--user-data-dir="%APPDATA%\ssh-client\gui_profile" --app-id="ssh-client" --no-first-run --disable-extensions --disable-features=Translate`.
4. Wait for window exit: when closed, run `"%~dp0ssh_client.bat" stop`.

- [ ] **Step 2: Verify zero emojis and test script**

Run: `python scripts/sync_release.py --emoji-check`

- [ ] **Step 3: Commit**

```bash
git add priv/launch-gui.bat priv/launch-gui.vbs
git commit -m "feat(launcher): add pre-flight health polling, isolated profile, and shutdown hook"
```

---

### Task 5: PWA Manifest & Window Styling

**Files:**
- Create: `priv/static/manifest.json`
- Modify: `lib/ssh_client_web/layouts/root.html.heex`

**Interfaces:**
- Consumes: Web App Manifest standard
- Produces: Dark titlebar styling and standalone window behavior for Windows app shell.

- [ ] **Step 1: Create priv/static/manifest.json**

```json
{
  "name": "ssh-client",
  "short_name": "ssh-client",
  "start_url": "/hosts",
  "display": "standalone",
  "background_color": "#050505",
  "theme_color": "#050505",
  "icons": [
    {
      "src": "/images/icon.png",
      "sizes": "192x192",
      "type": "image/png"
    }
  ]
}
```

- [ ] **Step 2: Update root.html.heex to link manifest and theme-color**

Add in `<head>`:
```html
<meta name="theme-color" content="#050505" />
<meta name="color-scheme" content="dark" />
<link rel="manifest" href="/manifest.json" />
```

- [ ] **Step 3: Commit**

```bash
git add priv/static/manifest.json lib/ssh_client_web/layouts/root.html.heex
git commit -m "feat(ui): add PWA standalone manifest and dark titlebar meta attributes"
```

---

### Task 6: Final Verification & Release Readiness

**Files:**
- Run: `python scripts/sync_release.py --check`
- Run: `python scripts/sync_release.py --emoji-check`
- Run: `python scripts/test_sync_release.py`
- Run: `git status`

- [ ] **Step 1: Run release verification checks**
- [ ] **Step 2: Verify git status is clean**
- [ ] **Step 3: Push branch and create pull request**
