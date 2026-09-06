# Design Spec: Native Windows Shell Lifecycle, Robust Auto-Updater, Security Hardening & Test Matrix Expansion

**Date**: 2026-09-06  
**Version**: 0.0.12-beta  
**Status**: Approved  

---

## 1. Overview & Architectural Goals

This specification resolves critical desktop lifecycle issues, eliminates in-place update failures on Windows, closes high-severity security vulnerabilities, and expands test suite coverage for **ssh-client**:

1. **Robust In-Place Windows & Linux Auto-Updater**: Eliminates process locking, non-interactive batch crashes, and silent failures during auto-updates.
2. **Dedicated Native Windows Shell & Process Lifecycle**: Provides a true desktop app feel with isolated profile, dark titlebar chrome, pre-launch health polling, and clean daemon shutdown on window close (preventing zombie erl.exe processes).
3. **Settings LiveView Crash Fix**: Restores missing Auth module alias in SettingsLive to eliminate UndefinedFunctionError on /settings.
4. **Production Security Hardening**: Restricts Bandit HTTP server strictly to 127.0.0.1:4000 (preventing unauthorized LAN/Wi-Fi exposure) and replaces hardcoded secret_key_base.
5. **Editorial Error Shell**: Replaces raw unstyled Internal server error with a styled dark editorial error page.
6. **Offline Asset Bundling**: Bundles xterm.js, Tailwind, daisyUI, and Phoenix client scripts in priv/static/ to enable 100% offline functionality.
7. **Test Suite Expansion**: Implements LiveView mount tests and comprehensive updater unit/staging tests.

---

## 2. Technical Architecture & Component Changes

### 2.1 Subsystem 1: Robust In-Place Auto-Updater
- **Module**: SSHClient.Updater (lib/ssh_client/updater.ex)
- **Windows Update Helper (apply_update.bat)**:
  - Replace timeout /t 2 /nobreak >nul with ping -n 3 127.0.0.1 >nul to prevent instant aborts in non-interactive / redirected sessions.
  - Terminate all running Erlang VM and node daemon processes before file replacement:
    taskkill /F /T /PID %TARGET_PID%
    taskkill /F /T /IM erl.exe
    taskkill /F /T /IM epmd.exe
    taskkill /F /T /IM werl.exe
    taskkill /F /T /IM beam.smp
  - Use verified file copy (robocopy "%STAGED%" "%TARGET%" /E /IS /IT /R:5 /W:1) instead of destructive /MOVE.
  - Validate that releases\start_erl.data exists and points to the new version before launching.
  - Log all operations to %APPDATA%\ssh-client\update.log instead of silencing with >nul 2>&1.
- **Linux Update Helper (apply_update.sh)**:
  - Change "#{target_dir}/bin/ssh_client daemon" to "#{target_dir}/bin/ssh_client start".
- **Inno Setup Silent Installer**:
  - When running .exe setup, ensure the post-install helper restarts the application cleanly.

### 2.2 Subsystem 2: Native Windows Shell & Lifecycle Controller
- **Files**: priv/launch-gui.bat, priv/launch-gui.vbs, windows/installer.iss
- **Architecture**:
  1. Pre-flight Check: Check if http://127.0.0.1:4000/ is already responding. If not, start the background daemon:
     start "" /b "%~dp0ssh_client.bat" start
  2. Health Poll Loop: Replace the blind timeout with a loop that polls http://127.0.0.1:4000/ until ready (up to 5 seconds).
  3. Isolated App Window:
     Launch Edge or Chrome with:
     - --app="http://127.0.0.1:4000"
     - --user-data-dir="%APPDATA%\ssh-client\gui_profile"
     - --app-id="ssh-client"
     - --no-first-run --disable-extensions --disable-features=Translate
     - Window dimensions: 1120x740
  4. Clean Daemon Shutdown on Exit:
     Wait for the browser window process to terminate, then cleanly run:
     call "%~dp0ssh_client.bat" stop
     This ensures erl.exe and epmd.exe never remain orphaned in Task Manager.

### 2.3 Subsystem 3: SettingsLive & Error Rendering Fixes
- **Module**: SSHClientWeb.SettingsLive (lib/ssh_client_web/live/settings_live.ex)
  - Restore alias SSHClient.SSH.Auth to fix Auth.resolve_identities().
- **Module**: SSHClientWeb.ErrorHTML (lib/ssh_client_web/controllers/error_html.ex)
  - Render an HTML template with <title>500 - Internal Server Error</title>, stark dark background (#050505), error code header, description, and link back to /hosts.

### 2.4 Subsystem 4: Security Hardening
- **Configuration**: config/prod.exs
  - Change http: [ip: {0, 0, 0, 0}, port: 4000] to http: [ip: {127, 0, 0, 1}, port: 4000].
  - Dynamic secret_key_base: If SECRET_KEY_BASE environment variable is not set, load or generate a 64-byte random key stored in %APPDATA%\ssh-client\secret_key_base.

### 2.5 Subsystem 5: Offline Asset Bundling
- **Files**: priv/static/, lib/ssh_client_web/layouts/root.html.heex
- Vendor static assets in priv/static/vendor/.
- Update root.html.heex to reference /vendor/... instead of https://cdn.jsdelivr.net/...

---

## 3. Testing & Verification Matrix

1. **Unit & Staging Tests**:
   - test/ssh_client/updater_test.exs: Test extract_archive/2, staging_dir/0, update script generation, and version comparisons.
   - test/ssh_client_web/settings_live_test.exs: Test mount/3 execution with unlocked vault, verifying key discovery and update check callbacks.
   - test/ssh_client_web/error_html_test.exs: Verify ErrorHTML.render/2 produces valid HTML documents with <title> and #050505 background.
2. **Release Checks**:
   - python scripts/sync_release.py --check
   - python scripts/sync_release.py --emoji-check
   - python scripts/test_sync_release.py
3. **End-to-End Verification**:
   - Trigger in-app update check in Settings.
   - Verify detached update helper logs to %APPDATA%\ssh-client\update.log.
   - Verify launcher cleans up erl.exe upon GUI exit.
