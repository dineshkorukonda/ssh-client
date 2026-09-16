# Full UI/UX Redesign: Left Sidebar, Host Table, Drawers & Workspace Polish

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform `ssh-client` to a modern IDE/Warp-style left sidebar layout, upgrade the host dashboard to a full interactive data table with a slide-over drawer for workspaces/port-forwards, enhance terminal tab/pane controls, improve SFTP breadcrumbs, and polish the vault security UI.

**Architecture:**
1. Introduce `<.sidebar_navigation>` and an `<.app_layout>` wrapper in `lib/ssh_client_web/core_components.ex` featuring a vertical left sidebar with active highlights, keyboard shortcuts, theme toggle, and vault lock.
2. Integrate the left sidebar layout across all views (`HostLive`, `TerminalLive`, `SFTPLive`, `SettingsLive`, `LogsLive`).
3. Revamp `host_live.html.heex` with a structured server data table and a slide-over right drawer for managing workspaces and port-forwards.
4. Upgrade `terminal_live.ex` toolbar with quick split buttons, font zoom, and active pane highlight rings.
5. Enhance `sftp_live.ex` with interactive breadcrumb segments and dropzone hover states.
6. Polish `lock_live.ex` security card with encryption badges.
7. Run complete pre-flight checks and tests.

**Tech Stack:** Phoenix LiveView 1.0, Tailwind CSS, DaisyUI, xterm.js, Elixir/OTP.

## Global Constraints
- **Zero Emojis**: Strictly no emojis anywhere in code, templates, or commits (AGENTS.md Rule 3).
- **Dark & Light dual theme**: Preserve full monochrome contrast support.
- **Pass all checks**: `python scripts/check.py` and `mix test` must pass 100%.

---

### Task 1: Sidebar Navigation in `core_components.ex`
- [ ] Add `<.sidebar_navigation>` with navigation items, status indicator, command palette button, theme switcher, and vault lock.
- [ ] Maintain `<.top_navigation>` compatibility so existing tests pass.
- [ ] Test in `core_components_test.exs`.

### Task 2: Implement Left Sidebar Layout across LiveViews
- [ ] Update `host_live.html.heex` to use sidebar layout.
- [ ] Update `terminal_live.ex` to use sidebar layout.
- [ ] Update `sftp_live.ex` to use sidebar layout.
- [ ] Update `settings_live.ex` to use sidebar layout.
- [ ] Update `logs_live.ex` to use sidebar layout.

### Task 3: Host Dashboard Data Table & Slide-Over Drawer
- [ ] Build clean server data table with status, host:port, user, metrics, and quick connect action buttons.
- [ ] Implement slide-over right drawer for Workspaces and Port Forwards.
- [ ] Add empty state when no servers configured.

### Task 4: Terminal & SFTP UX Polish
- [ ] Add quick split buttons, font zoom controls (+/-), and active pane ring to terminal workspace.
- [ ] Integrate clickable breadcrumbs for SFTP navigation.

### Task 5: Security / Lock Screen Polish
- [ ] Enhance `lock_live.ex` with PBKDF2 and AES-256 encryption badges.

### Task 6: Pre-flight Verification & Commit
- [ ] Run `mix format`.
- [ ] Run `mix test`.
- [ ] Run `python scripts/check.py`.
- [ ] Push to branch and monitor CI checks on PR #169.
