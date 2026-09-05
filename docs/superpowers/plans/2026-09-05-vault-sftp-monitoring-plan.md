# Master Vault Lock, SFTP Explorer, Monitoring Overhaul & Multi-Tab Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement client-side encrypted vault lock (AES-256-GCM + PBKDF2), native remote SFTP file explorer using OTP `:ssh_sftp`, real-time visual monitoring gauges with metric key fix, multi-tab terminal workspace, header `BETA` badge, and complete removal of all emojis across the application.

**Architecture:** Encrypted local DETS/JSON store managed by `SSHClient.Vault`; OTP `:ssh_sftp` client wrapper in `SSHClient.SFTP`; LiveView socket vault lock gate; metric path extraction fix with dynamic colored threshold bars; full multi-tab terminal state management in `SSHClientWeb.TerminalLive`.

**Tech Stack:** Elixir 1.18, Erlang/OTP 27 (`:crypto`, `:ssh_sftp`, `:ssh`), Phoenix LiveView 1.2, Tailwind CSS / DaisyUI, xterm.js.

**Spec:** `docs/superpowers/specs/2026-09-05-vault-sftp-monitoring-design.md`

## Global Constraints
- Zero emojis across the entire UI and codebase; use SVG icons or monospace text tags.
- Inverted white logo on dark backgrounds (`#050505`).
- `BETA` pill badge in header: `<span class="px-1.5 py-0.5 text-[10px] font-mono font-semibold uppercase tracking-wider rounded bg-red-500/10 text-red-400 border border-red-500/20">BETA</span>`.
- All credentials encrypted at rest with AES-256-GCM derived via PBKDF2.

---

### Task 1: Monitoring Key Path Fix & Multi-Threshold Visual Gauges

**Files:**
- Modify: `lib/ssh_client_web/live/host_live.ex:270-320, 420-435`
- Test: `test/ssh_client_web/host_live_test.exs`

**Interfaces:**
- Consumes: `SSHClient.ServerWorker.get_state/1` returning `%{metrics: %{cpu: %{used_percent: float()}, memory: %{used_percent: float()}, disk: %{used_percent: float()}}}`
- Produces: `format_server/1` returning properly mapped `cpu_percent`, `ram_percent`, `disk_percent`, `uptime`, `load_avg`

- [ ] **Step 1: Fix metric key path in `HostLive.format_server/1`**
Extract nested metric values:
```elixir
metrics = server[:metrics] || %{}
cpu_pct = get_in(metrics, [:cpu, :used_percent]) || metrics[:cpu_percent] || 0.0
ram_pct = get_in(metrics, [:memory, :used_percent]) || metrics[:ram_percent] || 0.0
disk_pct = get_in(metrics, [:disk, :used_percent]) || metrics[:disk_percent] || 0.0
load_1 = get_in(metrics, [:cpu, :load_1]) || 0.0
```

- [ ] **Step 2: Add visual threshold progress bar component in table columns**
Render compact colored bar + formatted percentage for CPU, RAM, and Disk:
```heex
<div class="flex items-center gap-2">
  <div class="w-16 h-1.5 bg-[#18181b] rounded-full overflow-hidden">
    <div class={["h-full rounded-full transition-all duration-500", bar_color(server.cpu_percent)]} style={"width: #{min(100.0, server.cpu_percent)}%"}></div>
  </div>
  <span class={["text-xs font-mono font-medium", metric_color(server.cpu_percent)]}>
    <%= format_pct(server.cpu_percent) %>
  </span>
</div>
```

- [ ] **Step 3: Make row Action buttons permanent and add SFTP action**
Remove `opacity-0 group-hover:opacity-100`, making `Terminal`, `SFTP`, `Refresh`, and `Delete` permanently visible and accessible.

- [ ] **Step 4: Commit Task 1**
```bash
git add lib/ssh_client_web/live/host_live.ex
git commit -m "fix(monitoring): correct metric key extraction, add visual gauge bars and persistent actions"
```

---

### Task 2: Header `BETA` Badge & Strict No-Emoji UI Cleanup

**Files:**
- Modify: `lib/ssh_client_web/layouts/root.html.heex`
- Modify: `lib/ssh_client_web/live/host_live.ex`
- Modify: `lib/ssh_client_web/live/terminal_live.ex`
- Modify: `lib/ssh_client_web/live/logs_live.ex`
- Modify: `lib/ssh_client_web/live/settings_live.ex`

- [ ] **Step 1: Add `BETA` pill badge next to logo in sidebar and headers**
```heex
<div class="px-5 py-4 border-b border-[#1f1f1f] flex items-center justify-between">
  <div class="flex items-center gap-3">
    <img src="/images/icon.png" alt="Logo" class="w-7 h-7 rounded-md invert" />
    <div>
      <span class="text-white font-semibold text-sm tracking-tight block">ssh-client</span>
      <span class="block text-[10px] text-zinc-600 font-mono">v0.0.1</span>
    </div>
  </div>
  <span class="px-1.5 py-0.5 text-[9px] font-mono font-bold tracking-wider rounded bg-red-500/10 text-red-400 border border-red-500/20">BETA</span>
</div>
```

- [ ] **Step 2: Replace all emojis in `TerminalLive` with clean SVG icons or monospace badges**
Replace `📋`, `⚡`, `🐚`, `🧹`, `▶`, `🔄` with inline SVG icons or `[PASTE]`, `[CMD]`, `[ZSH]`, `[CLEAR]`, `[RUN]`.

- [ ] **Step 3: Audit and sanitize all LiveViews to guarantee zero Unicode emojis**
Run verification search for emojis and verify clean rendering.

- [ ] **Step 4: Commit Task 2**
```bash
git add lib/ssh_client_web/
git commit -m "feat(branding): add BETA badge to header and remove all emojis in favor of SVG/text"
```

---

### Task 3: Master Password & Vault Encryption Module

**Files:**
- Create: `lib/ssh_client/vault.ex`
- Test: `test/ssh_client/vault_test.exs`

**Interfaces:**
- Produces:
  - `SSHClient.Vault.init_vault(master_password)` -> `{:ok, :initialized}`
  - `SSHClient.Vault.unlock(master_password)` -> `{:ok, :unlocked} | {:error, :invalid_password}`
  - `SSHClient.Vault.lock()` -> `:ok`
  - `SSHClient.Vault.status()` -> `:uninitialized | :locked | :unlocked`
  - `SSHClient.Vault.encrypt(plaintext)` -> `{:ok, ciphertext_b64}`
  - `SSHClient.Vault.decrypt(ciphertext_b64)` -> `{:ok, plaintext}`

- [ ] **Step 1: Write failing vault tests (`test/ssh_client/vault_test.exs`)**
```elixir
defmodule SSHClient.VaultTest do
  use ExUnit.Case, async: false
  alias SSHClient.Vault

  test "vault lifecycle: init -> unlock -> encrypt/decrypt -> lock" do
    assert Vault.status() in [:uninitialized, :locked, :unlocked]
  end
end
```

- [ ] **Step 2: Implement `SSHClient.Vault` GenServer with AES-256-GCM + PBKDF2**
Store encrypted master key verification token and salt in config directory DETS/JSON file.

- [ ] **Step 3: Run tests and verify PASS**
- [ ] **Step 4: Commit Task 3**
```bash
git add lib/ssh_client/vault.ex test/ssh_client/vault_test.exs
git commit -m "feat(security): implement master password vault with PBKDF2 and AES-256-GCM"
```

---

### Task 4: Vault Lock Screen & LiveView Authentication Gate

**Files:**
- Create: `lib/ssh_client_web/live/lock_live.ex`
- Modify: `lib/ssh_client_web/router.ex`
- Modify: `lib/ssh_client_web/layouts/root.html.heex`

- [ ] **Step 1: Implement `LockLive` setup and unlock screens**
Clean, modern dark lock screen allowing creation of master password on first launch or PIN/password entry when locked.

- [ ] **Step 2: Add LiveView `on_mount` authentication hook**
Redirect any unauthenticated access to `/lock` unless vault is in `:unlocked` state.

- [ ] **Step 3: Add `Lock Vault` button in sidebar footer**
Allow instantaneous manual lock with one click.

- [ ] **Step 4: Commit Task 4**
```bash
git add lib/ssh_client_web/live/lock_live.ex lib/ssh_client_web/router.ex
git commit -m "feat(security): add vault lock screen and session authentication gate"
```

---

### Task 5: Native SFTP Backend Client

**Files:**
- Create: `lib/ssh_client/sftp.ex`
- Test: `test/ssh_client/sftp_test.exs`

**Interfaces:**
- Produces:
  - `SSHClient.SFTP.start_channel(conn)` -> `{:ok, sftp_channel_pid}`
  - `SSHClient.SFTP.list_dir(sftp_pid, path)` -> `{:ok, [%{name: binary(), type: :regular | :directory | :symlink, size: integer(), permissions: integer(), mtime: integer()}]}`
  - `SSHClient.SFTP.read_file(sftp_pid, path)` -> `{:ok, binary()}`
  - `SSHClient.SFTP.write_file(sftp_pid, path, data)` -> `:ok | {:error, term()}`
  - `SSHClient.SFTP.delete(sftp_pid, path)` -> `:ok | {:error, term()}`
  - `SSHClient.SFTP.make_dir(sftp_pid, path)` -> `:ok | {:error, term()}`

- [ ] **Step 1: Implement `SSHClient.SFTP` wrapper using OTP `:ssh_sftp`**
- [ ] **Step 2: Add unit tests with mock/fixture**
- [ ] **Step 3: Commit Task 5**
```bash
git add lib/ssh_client/sftp.ex test/ssh_client/sftp_test.exs
git commit -m "feat(sftp): implement OTP :ssh_sftp wrapper for remote file operations"
```

---

### Task 6: Native SFTP File Explorer LiveView (`/sftp/:id`)

**Files:**
- Create: `lib/ssh_client_web/live/sftp_live.ex`
- Modify: `lib/ssh_client_web/router.ex`

- [ ] **Step 1: Build SFTP LiveView with Breadcrumb path navigation**
Support clicking folders to descend, parent directory `..`, file size formatting, and sorting by name/size/date.

- [ ] **Step 2: Implement File Upload & Download handlers**
Use Phoenix `allow_upload` for drag-and-drop file upload to remote directory and push binary download events.

- [ ] **Step 3: Implement Inline Text File Viewer / Editor modal**
Click text files (`.txt`, `.sh`, `.json`, `.yml`, `.conf`, `.env`) to view/edit and save changes back over SFTP.

- [ ] **Step 4: Commit Task 6**
```bash
git add lib/ssh_client_web/live/sftp_live.ex lib/ssh_client_web/router.ex
git commit -m "feat(sftp): add full SFTP file explorer LiveView with inline editor and file transfer"
```

---

### Task 7: Multi-Tab Terminal Support

**Files:**
- Modify: `lib/ssh_client_web/live/terminal_live.ex`

- [ ] **Step 1: Add Tab Bar to Terminal topbar**
Display active tabs (e.g. `[ server-1: shell 1 ]`, `[ server-2: shell 1 ]`, `[ + New Tab ]`).

- [ ] **Step 2: Manage concurrent PTY sessions in state**
Switching tabs swaps active xterm view without dropping background SSH connections.

- [ ] **Step 3: Commit Task 7**
```bash
git add lib/ssh_client_web/live/terminal_live.ex
git commit -m "feat(terminal): add multi-tab concurrent terminal session manager"
```

---

### Task 8: End-to-End Verification & GitHub Release

- [ ] **Step 1: Run comprehensive local verification**
- [ ] **Step 2: Commit all changes, tag `v0.0.1`, and push to trigger CI build**
- [ ] **Step 3: Verify GitHub Actions builds updated `.exe` installer**
- [ ] **Step 4: Download updated installer to user's `Downloads` folder**
