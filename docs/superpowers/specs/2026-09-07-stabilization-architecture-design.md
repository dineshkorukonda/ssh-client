# SSH Client — Complete Stabilization, Architecture, UX and Feature Redesign Specification

- **Date**: 2026-09-07
- **Version Target**: 0.0.x beta lifecycle
- **Status**: Approved Design Specification

---

## 1. Overview & Goals

Transform `ssh-client` into a production-grade, Windows-first, offline-first developer SSH/SFTP desktop application.

### Key Objectives
1. **Zero CDN Dependencies**: All Phoenix, LiveView, xterm.js, fonts, and assets bundled locally in `priv/static/`.
2. **Decoupled OTP Session Lifecycle**: SSH connections and PTY channels run in isolated `SSHClient.SessionWorker` GenServers. LiveView process mount/unmount or disconnect never terminates active SSH connections.
3. **Multi-Tab & Split-Pane Terminals**: Support 1 to 4 split panes per tab. Multiple panes connected to the same host instantiate independent SSH connections and PTY sessions.
4. **Two-Pane SFTP with Streaming Transfer Queue**: Full local-to-remote file manager with HTML5 drag-and-drop and chunked low-memory background streaming transfers with speed/ETA metrics.
5. **Hardened Vault & Secure Persistence**: PBKDF2-HMAC-SHA256 + AES-256-GCM vault with atomic file writes and OpenSSH config / key management.
6. **Robust Windows Desktop Launcher**: Startup health-check loop, geometry persistence, and clean crash recovery.
7. **Strict Aesthetic & Quality Standards**: 0 emojis across all code, UI, commits, and documentation; editorial dark monochrome design system.

---

## 2. Architecture & Supervision Tree

```text
SSHClient.Application (Supervisor)
│
├── Phoenix.PubSub (SSHClient.PubSub)
├── SSHClientWeb.Endpoint (Bandit / HTTP & WebSockets on 127.0.0.1:4000)
│
├── SSHClient.Store (Local Transactional Schema & Preferences)
├── SSHClient.Vault (PBKDF2 + AES-256-GCM Cryptographic Vault)
├── SSHClient.SessionSupervisor (DynamicSupervisor)
│     └── SSHClient.SessionWorker (one per tab/pane)
│           ├── OTP SSH Connection
│           ├── PTY Channel & State Machine
│           └── RingBuffer (Scrollback snapshot)
├── SSHClient.SessionManager (Registry & Session Lifecycle Coordinator)
├── SSHClient.SFTP.TransferSupervisor (DynamicSupervisor)
│     └── SSHClient.SFTP.TransferWorker (Async streaming chunk worker)
├── SSHClient.SFTP.TransferManager (Queue coordinator & Speed/ETA Telemetry)
└── SSHClient.Window (Desktop window launcher / WebView2 adapter)
```

---

## 3. Detailed Component Specifications

### 3.1 Local Asset Bundling & Offline Operation
* Bundle into `priv/static/`:
  * `priv/static/js/phoenix.min.js`
  * `priv/static/js/phoenix_live_view.min.js`
  * `priv/static/js/xterm.min.js` (xterm 5.3.0)
  * `priv/static/js/xterm-addon-fit.min.js`
  * `priv/static/js/xterm-addon-search.min.js`
  * `priv/static/js/xterm-addon-webgl.min.js`
  * `priv/static/js/app.js` (consolidated desktop hooks for Terminal, Split Panes, Dual-Pane SFTP drag/drop, Command Palette, and Themes)
  * `priv/static/css/xterm.min.css`
  * `priv/static/css/app.css` (Tailwind CSS + DaisyUI)
* Eliminate all external font and CDN URLs in `root.html.heex`.

### 3.2 SSH Session Manager & Split Panes
* **Session States**: `:disconnected`, `:connecting`, `:connected`, `:reconnecting`, `:disconnecting`, `:error`.
* **Exponential Backoff**: 1s, 2s, 5s, 10s, 30s with manual reconnect triggers.
* **Independent PTY per Pane**:
  * Splitting a terminal tab (Horizontal `Ctrl+Shift+\` or Vertical `Ctrl+Shift+-`) spawns a distinct `SessionWorker` with its own SSH connection and PTY channel.
* **Scrollback & Snapshot Recovery**:
  * Each `SessionWorker` maintains an in-memory `RingBuffer` (up to 10,000 lines).
  * When LiveView connects or switches tabs, the latest buffer snapshot is instantly transmitted to xterm.js without waiting for new remote output.

### 3.3 Two-Pane SFTP Manager & Background Transfer Queue
* **Dual Browser**: Local filesystem browser (left) and Remote SFTP browser (right) with breadcrumb navigation, sorting, hidden files toggle, and multi-select.
* **HTML5 Drag and Drop**: Drag files between local and remote panels to initiate transfers.
* **Streaming Chunks**:
  * Chunk size: 64 KB using `:ssh_sftp.open`, `:ssh_sftp.read`, `:ssh_sftp.write`, and `:ssh_sftp.close`.
  * Multi-gigabyte file transfers maintain constant O(1) memory usage.
* **Transfer Queue States**: `:queued`, `:preparing`, `:transferring`, `:completed`, `:failed`, `:cancelled`.
* **Telemetry**: Speed calculation (bytes/sec -> MB/s), remaining bytes, and dynamic ETA computation.

### 3.4 Storage, Security, Known Hosts & Vault
* **Structured Store**: Atomic JSON file writes with temp files to prevent corruption during unexpected shutdowns.
* **Vault**: Master password derivation using PBKDF2-HMAC-SHA256 (100,000 iterations) and AES-256-GCM authenticated encryption for passwords and private key passphrases.
* **Known Hosts**: Host-key validation against `~/.ssh/known_hosts`. Interactive acceptance dialog for new hosts; critical security alert for modified host keys.
* **SSH Config Import**: Parser for OpenSSH config files (`~/.ssh/config`) to auto-populate host entries.

### 3.5 Desktop Shell & Windows Integration
* **Health Check Startup**: Polling `http://127.0.0.1:4000/hosts` before launching the dedicated app-mode browser window or WebView2 container.
* **State Persistence**: Window dimensions, active workspace, open tabs, and split arrangements persisted across restarts.
* **Crash Recovery**: Option to restore previous open sessions on launch.

---

## 4. Testing & Verification Matrix

1. **Unit Tests**:
   * Session state machine transitions and backoff scheduling.
   * RingBuffer insertion, truncation, and snapshot export.
   * PBKDF2 + AES-256-GCM vault encryption, decryption, and locking.
   * OpenSSH config file parser.
   * SFTP path normalization and permissions formatting.
2. **LiveView & Component Tests**:
   * Terminal LiveView mount with local bundled JS hooks.
   * Split-pane layout rendering (single, horizontal, vertical, 2x2 grid).
   * Dual-pane SFTP file navigation and context menu events.
   * Global command palette (`Ctrl+K`) search and keyboard navigation.
3. **Integration & Streaming Tests**:
   * End-to-end SSH session worker lifecycle.
   * Chunked streaming upload and download over SFTP.
   * Transfer cancel and retry mechanics.
4. **Release & Style Verification**:
   * `python scripts/check.py` passing (emoji check, version sync, release tests).

---

## 5. Development Phases

* **Phase 1**: Local Asset Bundling, Windows Health-Check Launcher, Session Supervisor & Worker Core.
* **Phase 2**: Terminal Tabs, Split-Pane Topologies, Reconnect Logic, and RingBuffer Snapshots.
* **Phase 3**: Two-Pane SFTP File Manager, Streaming Chunk Transfer Queue, and Telemetry.
* **Phase 4**: Hardened Vault, Known Hosts Verification, Key Manager, and OpenSSH Config Importer.
* **Phase 5**: UI Redesign, Command Palette, Workspaces, and Crash Recovery.
* **Phase 6**: Packaging, Inno Setup Installer, Auto-Updater Hardening, CI Optimization, and Test Suite.
