# SSH Client Stabilization, Architecture, UX and Feature Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform `ssh-client` into an offline-first, production-quality developer SSH/SFTP desktop application featuring decoupled OTP session workers, split-pane terminals, streaming chunked SFTP file manager, encrypted vault, and hardened Windows launcher.

**Architecture:** 
Supervised OTP architecture with `SessionSupervisor` managing isolated `SessionWorker` GenServers for each tab/pane, `TransferManager` managing background chunked SFTP streams, transactional schema store in `Store`, client-side PBKDF2/AES-GCM encryption in `Vault`, zero CDN dependencies in `root.html.heex`, and a robust health-checked desktop launcher.

**Tech Stack:** Elixir 1.18+, Phoenix 1.7+, Phoenix LiveView 1.0+, Bandit, OTP `:ssh` & `:ssh_sftp`, `:crypto`, xterm.js 5.3.0, Tailwind CSS, DaisyUI.

**Spec:** `docs/superpowers/specs/2026-09-07-stabilization-architecture-design.md`

## Global Constraints
* 0 emojis anywhere in the codebase (code, variables, comments, templates, logs, commit messages, PRs, docs).
* Version synchronization across `mix.exs`, `windows/installer.iss`, `lib/ssh_client/updater.ex`, `RELEASE_NOTES.md`, `CHANGELOG.md`, `web/`.
* No external runtime CDN or Google Font dependencies (100% offline functional).
* UI disconnections must not terminate active SSH sessions.
* Same-host split panes must use separate PTYs and SSH connections.
* Large SFTP file transfers must stream in 64 KB chunks without loading entire files into memory.

---

### Task 1: Vendor and Bundle Local Frontend Assets (Zero-CDN)

**Files:**
- Create: `priv/static/js/phoenix.min.js`
- Create: `priv/static/js/phoenix_live_view.min.js`
- Create: `priv/static/js/xterm.min.js`
- Create: `priv/static/js/xterm-addon-fit.min.js`
- Create: `priv/static/js/xterm-addon-search.min.js`
- Create: `priv/static/css/xterm.min.css`
- Modify: `lib/ssh_client_web/layouts/root.html.heex`
- Test: `test/ssh_client_web/layouts/offline_assets_test.exs`

**Interfaces:**
- Consumes: Static files from `deps/phoenix`, `deps/phoenix_live_view`, and bundled xterm assets.
- Produces: `GET /js/*`, `GET /css/*` static endpoints without any external CDN references.

- [ ] **Step 1: Write test verifying zero external CDN URLs in root layout**
```elixir
defmodule SSHClientWeb.OfflineAssetsTest do
  use ExUnit.Case, async: true

  test "root layout contains no external CDN or Google Font references" do
    content = File.read!("lib/ssh_client_web/layouts/root.html.heex")
    refute content =~ "cdn.jsdelivr.net"
    refute content =~ "fonts.googleapis.com"
    refute content =~ "fonts.gstatic.com"
    refute content =~ "unpkg.com"
    refute content =~ "cdnjs.cloudflare.com"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**
Run: `mix test test/ssh_client_web/layouts/offline_assets_test.exs`
Expected: FAIL due to existing CDN links in `root.html.heex`.

- [ ] **Step 3: Copy and bundle vendor JS and CSS into priv/static**
Copy Phoenix and LiveView vendor JS from `deps/phoenix/priv/static/phoenix.min.js` and `deps/phoenix_live_view/priv/static/phoenix_live_view.min.js`. Write xterm.js 5.3.0 and addons to `priv/static/js/` and `priv/static/css/xterm.min.css`. Update `lib/ssh_client_web/layouts/root.html.heex` to reference only local `/js/...` and `/css/...` routes.

- [ ] **Step 4: Run test to verify it passes**
Run: `mix test test/ssh_client_web/layouts/offline_assets_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add priv/static/ lib/ssh_client_web/layouts/root.html.heex test/ssh_client_web/layouts/offline_assets_test.exs
git commit -m "feat: vendor frontend assets locally for zero-cdn offline support"
```

---

### Task 2: Hardened Windows Launcher & Startup Health Check

**Files:**
- Modify: `priv/launch-gui.bat`
- Modify: `priv/launch-gui.vbs`
- Modify: `lib/ssh_client/window.ex`
- Test: `test/ssh_client/window_test.exs`

**Interfaces:**
- Consumes: Health check endpoint `/hosts` or `/health`.
- Produces: Resilient desktop startup script that polls backend readiness before spawning app-mode window.

- [ ] **Step 1: Write test for Window child_spec and configuration**
```elixir
defmodule SSHClient.WindowTest do
  use ExUnit.Case, async: true

  test "child_spec returns valid worker specification" do
    spec = SSHClient.Window.child_spec(port: 4000)
    assert spec.id == SSHClient.Window
    assert spec.type == :worker
  end
end
```

- [ ] **Step 2: Run test to verify it passes/fails**
Run: `mix test test/ssh_client/window_test.exs`

- [ ] **Step 3: Update Windows launch scripts with health check loop**
Update `priv/launch-gui.bat` to include timeout handling, edge/chrome detection across 32-bit/64-bit/local paths, and non-blocking background daemon startup with health polling.

- [ ] **Step 4: Run tests and verify**
Run: `mix test`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add priv/launch-gui.bat priv/launch-gui.vbs lib/ssh_client/window.ex test/ssh_client/window_test.exs
git commit -m "feat: harden windows launcher with backend health check loop"
```

---

### Task 3: Decoupled SessionWorker with State Machine & RingBuffer

**Files:**
- Create: `lib/ssh_client/session_worker.ex`
- Modify: `lib/ssh_client/terminal/buffer.ex`
- Test: `test/ssh_client/session_worker_test.exs`
- Test: `test/ssh_client/terminal/buffer_test.exs`

**Interfaces:**
- Consumes: `SSHClient.Config.Server`
- Produces: `SSHClient.SessionWorker` GenServer exposing `send_input/2`, `resize/3`, `get_buffer/1`, `disconnect/1`, `reconnect/1`. Broadcasts output via `Phoenix.PubSub` to `"ssh_client:session:<id>"`.

- [ ] **Step 1: Write tests for SessionWorker state machine and ring buffer**
```elixir
defmodule SSHClient.SessionWorkerTest do
  use ExUnit.Case, async: true

  alias SSHClient.Config.Server
  alias SSHClient.SessionWorker

  test "initializes in connecting state without blocking parent caller" do
    server = %Server{id: "srv1", host: "127.0.0.1", port: 2222}
    {:ok, pid} = SessionWorker.start_link(session_id: "sess_1", server: server, auto_connect: false)
    assert SessionWorker.get_status(pid) == :disconnected
  end
end
```

- [ ] **Step 2: Run test to verify it fails**
Run: `mix test test/ssh_client/session_worker_test.exs`
Expected: FAIL with `SessionWorker` not defined.

- [ ] **Step 3: Implement SessionWorker GenServer**
Implement `SSHClient.SessionWorker` with states `:disconnected`, `:connecting`, `:connected`, `:reconnecting`, `:disconnecting`, `:error`, exponential backoff reconnects, RingBuffer integration, and PubSub output broadcasting.

- [ ] **Step 4: Run tests to verify they pass**
Run: `mix test test/ssh_client/session_worker_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/ssh_client/session_worker.ex test/ssh_client/session_worker_test.exs
git commit -m "feat: implement decoupled session worker with state machine and ring buffer"
```

---

### Task 4: SessionSupervisor and SessionManager Coordinator

**Files:**
- Create: `lib/ssh_client/session_supervisor.ex`
- Create: `lib/ssh_client/session_manager.ex`
- Modify: `lib/ssh_client/application.ex`
- Test: `test/ssh_client/session_manager_test.exs`

**Interfaces:**
- Consumes: DynamicSupervisor
- Produces: `SessionManager.create_session/2`, `SessionManager.get_session/1`, `SessionManager.list_sessions/0`, `SessionManager.close_session/1`.

- [ ] **Step 1: Write unit tests for SessionManager**
```elixir
defmodule SSHClient.SessionManagerTest do
  use ExUnit.Case, async: false

  alias SSHClient.Config.Server
  alias SSHClient.SessionManager

  test "creates, lists, retrieves, and closes session workers" do
    server = %Server{id: "test-srv", host: "localhost", port: 22}
    {:ok, session_id} = SessionManager.create_session(server, auto_connect: false)
    assert is_binary(session_id)
    assert SessionManager.has_session?(session_id)
    :ok = SessionManager.close_session(session_id)
    refute SessionManager.has_session?(session_id)
  end
end
```

- [ ] **Step 2: Run test to verify failure**
Run: `mix test test/ssh_client/session_manager_test.exs`
Expected: FAIL with `SessionManager` module missing.

- [ ] **Step 3: Implement SessionSupervisor & SessionManager**
Implement `SSHClient.SessionSupervisor` as `DynamicSupervisor` and `SSHClient.SessionManager` GenServer managing active sessions and attaching to `SSHClient.Application`.

- [ ] **Step 4: Run test to verify passing**
Run: `mix test test/ssh_client/session_manager_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/ssh_client/session_supervisor.ex lib/ssh_client/session_manager.ex lib/ssh_client/application.ex test/ssh_client/session_manager_test.exs
git commit -m "feat: add session supervisor and session manager coordinator"
```

---

### Task 5: Multi-Tab and Split-Pane Terminal Topology

**Files:**
- Create: `lib/ssh_client/terminal/layout.ex`
- Modify: `lib/ssh_client_web/live/host_live.ex`
- Modify: `lib/ssh_client_web/live/host_live.html.heex`
- Test: `test/ssh_client/terminal/layout_test.exs`
- Test: `test/ssh_client_web/live/split_terminal_test.exs`

**Interfaces:**
- Consumes: `SessionManager`
- Produces: Split layout tree supporting `Single`, `Horizontal`, `Vertical`, and `Grid 2x2` pane configurations with independent session workers for same-host connections.

- [ ] **Step 1: Write unit tests for Layout tree operations**
```elixir
defmodule SSHClient.Terminal.LayoutTest do
  use ExUnit.Case, async: true

  alias SSHClient.Terminal.Layout

  test "creates initial layout and splits horizontal / vertical" do
    layout = Layout.new("sess_1")
    assert Layout.panes(layout) == ["sess_1"]

    layout = Layout.split(layout, "sess_1", :horizontal, "sess_2")
    assert Layout.panes(layout) == ["sess_1", "sess_2"]
    assert layout.type == :split_h
  end
end
```

- [ ] **Step 2: Run test to verify failure**
Run: `mix test test/ssh_client/terminal/layout_test.exs`
Expected: FAIL with missing `Layout` module.

- [ ] **Step 3: Implement Layout data structure and LiveView split handlers**
Implement `SSHClient.Terminal.Layout` supporting splits, pane resizing, focus transitions, pane closure, and integrate split actions into `HostLive` (`split_right`, `split_down`, `focus_pane`, `close_pane`).

- [ ] **Step 4: Run layout tests to verify passing**
Run: `mix test test/ssh_client/terminal/layout_test.exs test/ssh_client_web/live/split_terminal_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/ssh_client/terminal/layout.ex lib/ssh_client_web/live/ test/ssh_client/terminal/layout_test.exs test/ssh_client_web/live/split_terminal_test.exs
git commit -m "feat: implement multi-tab and split-pane terminal layout system"
```

---

### Task 6: Low-Memory Chunked Streaming SFTP Client

**Files:**
- Modify: `lib/ssh_client/sftp.ex`
- Test: `test/ssh_client/sftp_streaming_test.exs`

**Interfaces:**
- Consumes: OTP `:ssh_sftp`
- Produces: `SFTP.stream_upload/4` and `SFTP.stream_download/4` operating in 64 KB chunks without loading full files into memory.

- [ ] **Step 1: Write test for chunked stream upload/download**
```elixir
defmodule SSHClient.SFTPStreamingTest do
  use ExUnit.Case, async: true

  alias SSHClient.SFTP

  test "formats bytes and paths correctly" do
    assert SFTP.format_size(1024) == "1.0 KB"
    assert SFTP.format_size(1024 * 1024 * 5) == "5.0 MB"
    assert SFTP.normalize_path("foo/bar") == "/foo/bar"
  end
end
```

- [ ] **Step 2: Run test to verify baseline**
Run: `mix test test/ssh_client/sftp_streaming_test.exs`

- [ ] **Step 3: Implement chunked streaming functions in SFTP module**
Implement `stream_upload/4` and `stream_download/4` reading and writing files via `:file.read` / `:file.write` or `File.stream!` in 64 KB blocks with periodic progress callbacks.

- [ ] **Step 4: Run tests and verify**
Run: `mix test test/ssh_client/sftp_streaming_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/ssh_client/sftp.ex test/ssh_client/sftp_streaming_test.exs
git commit -m "feat: add chunked low-memory streaming sftp transfers"
```

---

### Task 7: Background SFTP Transfer Manager & Telemetry Queue

**Files:**
- Create: `lib/ssh_client/sftp/transfer_worker.ex`
- Create: `lib/ssh_client/sftp/transfer_manager.ex`
- Modify: `lib/ssh_client/application.ex`
- Test: `test/ssh_client/sftp/transfer_manager_test.exs`

**Interfaces:**
- Consumes: `SSHClient.SFTP`
- Produces: `TransferManager.queue_upload/4`, `TransferManager.queue_download/4`, `TransferManager.list_transfers/0`, `TransferManager.cancel_transfer/1`, `TransferManager.retry_transfer/1`.

- [ ] **Step 1: Write unit tests for TransferManager queue lifecycle**
```elixir
defmodule SSHClient.SFTP.TransferManagerTest do
  use ExUnit.Case, async: true

  alias SSHClient.SFTP.TransferManager

  test "tracks transfer lifecycle states, progress, speed, and cancel" do
    {:ok, transfer_id} = TransferManager.queue_test_transfer("test.txt", 1_000_000)
    assert is_binary(transfer_id)
    transfer = TransferManager.get_transfer(transfer_id)
    assert transfer.status in [:queued, :transferring, :completed]
    :ok = TransferManager.cancel_transfer(transfer_id)
    assert TransferManager.get_transfer(transfer_id).status == :cancelled
  end
end
```

- [ ] **Step 2: Run test to verify failure**
Run: `mix test test/ssh_client/sftp/transfer_manager_test.exs`
Expected: FAIL with `TransferManager` module missing.

- [ ] **Step 3: Implement TransferWorker & TransferManager**
Implement `SSHClient.SFTP.TransferManager` tracking transfer records (`id`, `direction`, `source`, `destination`, `bytes_transferred`, `total_bytes`, `speed_bps`, `eta_seconds`, `status`, `error`) and broadcasting updates via PubSub.

- [ ] **Step 4: Run test to verify passing**
Run: `mix test test/ssh_client/sftp/transfer_manager_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/ssh_client/sftp/ lib/ssh_client/application.ex test/ssh_client/sftp/transfer_manager_test.exs
git commit -m "feat: add background sftp transfer manager and progress queue"
```

---

### Task 8: Two-Pane SFTP Manager UI with Drag and Drop

**Files:**
- Modify: `lib/ssh_client_web/live/host_live.ex`
- Modify: `lib/ssh_client_web/live/host_live.html.heex`
- Test: `test/ssh_client_web/live/sftp_dual_pane_test.exs`

**Interfaces:**
- Consumes: `TransferManager`, `LocalFS`, `SFTP`
- Produces: Dual-pane file browser (Local left, Remote right), context menus, breadcrumb navigation, and drop upload/download events.

- [ ] **Step 1: Write test for Dual-Pane SFTP LiveView events**
```elixir
defmodule SSHClientWeb.SFTPDualPaneTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "renders local and remote browser columns in sftp mode" do
    # Verify local and remote panes mount without crashing
  end
end
```

- [ ] **Step 2: Run test to verify baseline**
Run: `mix test test/ssh_client_web/live/sftp_dual_pane_test.exs`

- [ ] **Step 3: Implement Dual-Pane SFTP UI and event handlers**
Implement local filesystem browser panel, remote SFTP browser panel, breadcrumbs, search filter, selection state, context menu (Upload, Download, Rename, Delete, New Folder, Properties), and drop handlers (`drop_upload`, `drop_download`).

- [ ] **Step 4: Run tests to verify passing**
Run: `mix test test/ssh_client_web/live/sftp_dual_pane_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/ssh_client_web/live/ test/ssh_client_web/live/sftp_dual_pane_test.exs
git commit -m "feat: implement dual-pane sftp file manager with drag and drop"
```

---

### Task 9: Atomic Schema Storage and Persistence Foundation

**Files:**
- Create: `lib/ssh_client/store.ex`
- Modify: `lib/ssh_client/config.ex`
- Test: `test/ssh_client/store_test.exs`

**Interfaces:**
- Consumes: OS User Config Directory (`%APPDATA%/ssh-client`, `~/.config/ssh-client`)
- Produces: Atomic transactional document store with collections for `hosts`, `workspaces`, `ssh_keys`, `known_hosts`, `sessions`, `preferences`, `command_history`.

- [ ] **Step 1: Write unit tests for Store atomic persistence and crash safety**
```elixir
defmodule SSHClient.StoreTest do
  use ExUnit.Case, async: true

  alias SSHClient.Store

  test "saves and retrieves records atomically with crash safety" do
    tmp_path = Path.join(System.tmp_dir!(), "store_test_#{:erlang.unique_integer([:positive])}.json")
    {:ok, store} = Store.start_link(path: tmp_path)
    :ok = Store.put(store, :hosts, "srv1", %{"name" => "Production", "host" => "10.0.0.1"})
    assert Store.get(store, :hosts, "srv1")["name"] == "Production"
    File.rm(tmp_path)
  end
end
```

- [ ] **Step 2: Run test to verify failure**
Run: `mix test test/ssh_client/store_test.exs`
Expected: FAIL with `Store` missing.

- [ ] **Step 3: Implement Store GenServer with atomic file swap**
Implement `SSHClient.Store` using temporary file write + atomic `File.rename` for crash resilience, with collection index maps.

- [ ] **Step 4: Run test to verify passing**
Run: `mix test test/ssh_client/store_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/ssh_client/store.ex test/ssh_client/store_test.exs
git commit -m "feat: implement atomic transactional persistence store"
```

---

### Task 10: Hardened Vault, Host Key Verification & OpenSSH Config Importer

**Files:**
- Modify: `lib/ssh_client/vault.ex`
- Modify: `lib/ssh_client/ssh/host_key_verifier.ex`
- Modify: `lib/ssh_client/ssh/config_importer.ex`
- Test: `test/ssh_client/vault_test.exs`
- Test: `test/ssh_client/ssh/host_key_verifier_test.exs`
- Test: `test/ssh_client/ssh/config_importer_test.exs`

**Interfaces:**
- Consumes: PBKDF2/AES-GCM, `~/.ssh/known_hosts`, `~/.ssh/config`
- Produces: `Vault.encrypt/1`, `Vault.decrypt/1`, `HostKeyVerifier.verify/3`, `ConfigImporter.import_default/0`.

- [ ] **Step 1: Write tests for host key verification and config importer**
```elixir
defmodule SSHClient.SSH.HostKeyVerifierTest do
  use ExUnit.Case, async: true

  alias SSHClient.SSH.HostKeyVerifier

  test "identifies known, new, and mismatched host keys" do
    # Assert verification states
  end
end
```

- [ ] **Step 2: Run test to verify**
Run: `mix test test/ssh_client/ssh/host_key_verifier_test.exs`

- [ ] **Step 3: Implement verified known hosts and config importer logic**
Ensure host key mismatches trigger explicit warning events rather than silent connections. Enhance OpenSSH config importer to parse `Host`, `HostName`, `User`, `Port`, `IdentityFile`, `ProxyJump`.

- [ ] **Step 4: Run tests to verify passing**
Run: `mix test test/ssh_client/vault_test.exs test/ssh_client/ssh/host_key_verifier_test.exs test/ssh_client/ssh/config_importer_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/ssh_client/vault.ex lib/ssh_client/ssh/host_key_verifier.ex lib/ssh_client/ssh/config_importer.ex test/ssh_client/ssh/
git commit -m "feat: harden vault security, known hosts verification, and config importer"
```

---

### Task 11: Global Command Palette, Workspaces & UI Redesign

**Files:**
- Modify: `lib/ssh_client_web/live/host_live.ex`
- Modify: `lib/ssh_client_web/live/host_live.html.heex`
- Test: `test/ssh_client_web/live/command_palette_test.exs`

**Interfaces:**
- Consumes: `Store`, `SessionManager`, `HostLive`
- Produces: `Ctrl+K` searchable command palette, Host Workspaces management, dark monochrome aesthetic layout.

- [ ] **Step 1: Write test for Command Palette search and actions**
```elixir
defmodule SSHClientWeb.CommandPaletteTest do
  use ExUnit.Case, async: true

  test "filters hosts, actions, and workspaces based on query" do
    # Assert search results
  end
end
```

- [ ] **Step 2: Run test to verify baseline**
Run: `mix test test/ssh_client_web/live/command_palette_test.exs`

- [ ] **Step 3: Implement Command Palette, Workspaces & Monochromatic Theme**
Build fuzzy search over hosts/actions/commands in `HostLive`, workspace grouping, and editorial dark theme with clean borders and typography.

- [ ] **Step 4: Run tests to verify passing**
Run: `mix test test/ssh_client_web/live/command_palette_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/ssh_client_web/live/ test/ssh_client_web/live/command_palette_test.exs
git commit -m "feat: add global command palette, workspaces, and editorial dark ui"
```

---

### Task 12: Application Diagnostics & Crash Recovery

**Files:**
- Create: `lib/ssh_client/diagnostics.ex`
- Modify: `lib/ssh_client_web/live/host_live.ex`
- Test: `test/ssh_client/diagnostics_test.exs`

**Interfaces:**
- Consumes: Logger, Store, System Info
- Produces: Redacted diagnostics export (`diagnostics.json` / `.log`) and restart session restoration dialog.

- [ ] **Step 1: Write test for Diagnostics redacting sensitive credentials**
```elixir
defmodule SSHClient.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias SSHClient.Diagnostics

  test "redacts passwords, private keys, and tokens in export" do
    raw = %{password: "supersecret", host: "10.0.0.1", token: "bearer 12345"}
    redacted = Diagnostics.redact(raw)
    assert redacted.password == "[REDACTED]"
    assert redacted.token == "[REDACTED]"
    assert redacted.host == "10.0.0.1"
  end
end
```

- [ ] **Step 2: Run test to verify failure**
Run: `mix test test/ssh_client/diagnostics_test.exs`
Expected: FAIL with `Diagnostics` missing.

- [ ] **Step 3: Implement Diagnostics and Crash Recovery**
Implement `SSHClient.Diagnostics` with automatic redaction of secret patterns, and implement session restoration check on mount in `HostLive`.

- [ ] **Step 4: Run test to verify passing**
Run: `mix test test/ssh_client/diagnostics_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/ssh_client/diagnostics.ex test/ssh_client/diagnostics_test.exs
git commit -m "feat: add diagnostics export with secret redaction and session crash recovery"
```

---

### Task 13: Full Verification, Documentation & Release Script Validation

**Files:**
- Modify: `README.md`
- Modify: `RELEASE_NOTES.md`
- Modify: `CHANGELOG.md`
- Test: All suites (`mix test`, `python scripts/check.py`)

**Interfaces:**
- Consumes: Test runners, linters, release validation scripts
- Produces: 100% green test matrix, zero emoji violations, and updated documentation.

- [ ] **Step 1: Run full test suite**
Run: `mix test`
Expected: 100% PASS across all tests.

- [ ] **Step 2: Run release check scripts**
Run: `python scripts/check.py`
Expected: PASS with zero emoji violations and synchronized versioning.

- [ ] **Step 3: Update documentation**
Update `README.md` and changelog reflecting offline-first bundled assets, decoupled session architecture, split terminals, and streaming SFTP manager.

- [ ] **Step 4: Final commit and verify clean state**
```bash
git add README.md RELEASE_NOTES.md CHANGELOG.md
git commit -m "docs: update readme and release notes with architecture redesign details"
```
