# Modern Developer Console UI & Layout Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the application interface across all views into a unified, high-contrast Modern Developer Console featuring an integrated persistent topbar with breadcrumbs, global search shortcut, reachability metrics, collapsible sidebar, standardized page headers, and maximized workspace canvases for Terminal and SFTP.

**Architecture:** Extend Phoenix LiveView layout components in `lib/ssh_client_web/core_components.ex` with a persistent topbar, standardized `.page_header`, and `.console_toolbar` primitives. Update `Hosts`, `Terminal`, `SFTP`, `Logs`, `Settings`, and `Lock` LiveViews to adopt the unified shell while maintaining strict zero-emoji compliance and editorial stark dark aesthetics.

**Tech Stack:** Elixir / Phoenix LiveView 1.0, Tailwind CSS, xterm.js, OTP GenServers.

**Spec:** [`docs/superpowers/specs/2026-09-20-modern-developer-console-design.md`](file:///C:/Users/dines/Developer/ssh-client/docs/superpowers/specs/2026-09-20-modern-developer-console-design.md)

## Global Constraints
- Strictly zero emojis in code, variable names, comments, UI text, icons, buttons, commit messages, and PR titles.
- Use semantic SVG icons and clean monospace typography (`JetBrains Mono`, `Cascadia Code`, `Consolas`).
- Maintain dark and light theme token compatibility (`hsl(var(--background))`, `hsl(var(--foreground))`, `hsl(var(--border))`, etc.).
- All tests must pass: `mix test` and `python scripts/check.py`.
- Formatted via `mix format --check-formatted`.

---

### Task 1: Core Shell Upgrade (`app_shell` & Layout Primitives)

**Files:**
- Modify: `lib/ssh_client_web/core_components.ex:1-350`
- Test: `test/ssh_client_web/core_components_test.exs`

**Interfaces:**
- Consumes: `current_tab`, `version`, `servers_count`, `online_count`, `breadcrumbs` (list of `%{label: string, to: string | nil}`).
- Produces: `<.app_shell>`, `<.page_header>`, `<.console_toolbar>`, `<.status_badge>`.

- [ ] **Step 1: Write tests for `app_shell` and layout primitives**
Create `test/ssh_client_web/core_components_test.exs` asserting that `app_shell`, `page_header`, and `console_toolbar` render expected semantic markup without errors.

- [ ] **Step 2: Run test to verify failure**
Run: `mix test test/ssh_client_web/core_components_test.exs`
Expected: FAIL if new primitives or attributes are missing.

- [ ] **Step 3: Implement updated `app_shell` and components in `core_components.ex`**
1. Add integrated sticky topbar to `app_shell`:
   - Left: Logo `>_ ssh-client`, version badge `v#{@version} BETA`, and interactive breadcrumbs.
   - Right: Command palette trigger (`Ctrl+K`), reachable server stats badge (`#{@online_count}/#{@servers_count}`), theme switch button, and vault lock button.
2. Refactor `sidebar_navigation`:
   - High-contrast active tab border and background.
   - Clean SVG icons for `Hosts`, `Terminal`, `SFTP`, `Logs`, and `Settings`.
3. Add `<.page_header>` and `<.console_toolbar>` functional components.

- [ ] **Step 4: Run tests to verify they pass**
Run: `mix test test/ssh_client_web/core_components_test.exs`
Expected: PASS

- [ ] **Step 5: Commit changes**
```bash
git add lib/ssh_client_web/core_components.ex test/ssh_client_web/core_components_test.exs
git commit -m "feat(ui): upgrade app_shell with integrated topbar and page primitives"
```

---

### Task 2: Hosts Management & Dashboard Redesign

**Files:**
- Modify: `lib/ssh_client_web/live/host_live.html.heex:1-120`
- Modify: `lib/ssh_client_web/live/host_live.ex`
- Test: `test/ssh_client_web/live/host_live_test.exs`

**Interfaces:**
- Consumes: `<.app_shell>`, `<.page_header>`, `<.console_toolbar>`.
- Produces: Streamlined host cards with unified elevation, status dots, and action footers.

- [ ] **Step 1: Update test assertions for `HostLive`**
Verify route mount, presence of `<.page_header>`, and server card render in `test/ssh_client_web/live/host_live_test.exs`.

- [ ] **Step 2: Run test to observe baseline**
Run: `mix test test/ssh_client_web/live/host_live_test.exs`

- [ ] **Step 3: Refactor `host_live.html.heex`**
- Replace custom headers with `<.page_header title="Managed Infrastructure" ...>`.
- Embed `<.console_toolbar>` containing search input, `Import ~/.ssh/config`, `Poll All`, `Save Workspace`, and `Add Server`.
- Standardize server cards with consistent padding, font hierarchy, online status dot, and button group (`Terminal`, `SFTP`, `Edit`, `Delete`).

- [ ] **Step 4: Run tests to verify passing**
Run: `mix test test/ssh_client_web/live/host_live_test.exs`
Expected: PASS

- [ ] **Step 5: Commit changes**
```bash
git add lib/ssh_client_web/live/host_live.html.heex lib/ssh_client_web/live/host_live.ex test/ssh_client_web/live/host_live_test.exs
git commit -m "feat(ui): redesign hosts dashboard with unified toolbar and cards"
```

---

### Task 3: Terminal Workspace Redesign & Edge-to-Edge Canvas

**Files:**
- Modify: `lib/ssh_client_web/live/terminal_live.ex:920-1250`
- Test: `test/ssh_client_web/terminal_live_test.exs`

**Interfaces:**
- Consumes: `<.app_shell full_bleed={true}>`
- Produces: Edge-to-edge terminal layout, unified multi-tab toolbar, split controls, and keyboard shortcuts modal.

- [ ] **Step 1: Update terminal test assertions**
Update `test/ssh_client_web/terminal_live_test.exs` to verify picker rendering and active session rendering.

- [ ] **Step 2: Run terminal tests**
Run: `mix test test/ssh_client_web/terminal_live_test.exs`

- [ ] **Step 3: Refactor `terminal_live.ex` render functions**
- Update server picker when `@server_id` is nil to use the standardized card grid and `<.page_header>`.
- In active terminal session, use `compact={true}` and full-bleed layout.
- Clean up the terminal topbar: multi-tab tabs with connection status dots, close buttons, `+` tab button, `Split Right`, `Split Down`, clear terminal, font size controls, and keyboard shortcuts `?` button.

- [ ] **Step 4: Run terminal tests to verify passing**
Run: `mix test test/ssh_client_web/terminal_live_test.exs`
Expected: PASS

- [ ] **Step 5: Commit changes**
```bash
git add lib/ssh_client_web/live/terminal_live.ex test/ssh_client_web/terminal_live_test.exs
git commit -m "feat(terminal): polish edge-to-edge multi-tab workspace and picker"
```

---

### Task 4: SFTP File Explorer & Dual-Pane Canvas Redesign

**Files:**
- Modify: `lib/ssh_client_web/live/sftp_live.ex:650-1360`
- Test: `test/ssh_client_web/sftp_live_test.exs`

**Interfaces:**
- Consumes: `<.app_shell full_bleed={true}>`
- Produces: Edge-to-edge dual-pane file manager, bottom transfer queue dock with live speed & ETA, and inline code editor with line numbering.

- [ ] **Step 1: Update SFTP test assertions**
Ensure `test/ssh_client_web/sftp_live_test.exs` checks throughput and line number helpers as well as layout rendering.

- [ ] **Step 2: Run SFTP tests**
Run: `mix test test/ssh_client_web/sftp_live_test.exs`

- [ ] **Step 3: Refactor `sftp_live.ex` render functions**
- Unify server picker when `@server_id` is nil with `<.page_header>` and standardized cards.
- Refactor dual-pane workspace: edge-to-edge side-by-side panes with consistent header bars, path navigation breadcrumbs, and quick-jump links.
- Polish bottom transfer queue dock with throughput (`KB/s`, `MB/s`), remaining `ETA`, and cancel/retry controls.
- Polish inline code editor modal with clean line numbering gutter and save/close actions.

- [ ] **Step 4: Run SFTP tests to verify passing**
Run: `mix test test/ssh_client_web/sftp_live_test.exs`
Expected: PASS

- [ ] **Step 5: Commit changes**
```bash
git add lib/ssh_client_web/live/sftp_live.ex test/ssh_client_web/sftp_live_test.exs
git commit -m "feat(sftp): modern dual-pane explorer with throughput ETA and lined editor"
```

---

### Task 5: Logs, Settings, and Vault Lock Screen Harmonization

**Files:**
- Modify: `lib/ssh_client_web/live/logs_live.ex`
- Modify: `lib/ssh_client_web/live/settings_live.ex`
- Modify: `lib/ssh_client_web/live/lock_live.ex`
- Test: `test/ssh_client_web/logs_live_test.exs`, `test/ssh_client_web/settings_live_test.exs`, `test/ssh_client_web/lock_live_test.exs`

**Interfaces:**
- Consumes: `<.app_shell>`, `<.page_header>`, `<.console_toolbar>`.
- Produces: Consistent header banners, monospace telemetry tables, settings diagnostic cards, and minimalist lock screen.

- [ ] **Step 1: Run tests for Logs, Settings, and Lock**
Run: `mix test test/ssh_client_web/logs_live_test.exs test/ssh_client_web/settings_live_test.exs test/ssh_client_web/lock_live_test.exs`

- [ ] **Step 2: Refactor `LogsLive`**
- Wrap with `<.page_header title="Activity & Telemetry Logs" ...>`.
- Modernize server and level filter bar with `<.console_toolbar>`.
- Refine monospace log table typography, border dividers, and detail view modal.

- [ ] **Step 3: Refactor `SettingsLive`**
- Wrap with `<.page_header title="Settings & Diagnostics" ...>`.
- Refine settings category tabs, high-contrast cards for key discovery, updater checks, and diagnostic JSON viewer.

- [ ] **Step 4: Refactor `LockLive`**
- Polish centered terminal security card with crisp borders, master password inputs, and clean action buttons.

- [ ] **Step 5: Run tests across all three modules**
Run: `mix test test/ssh_client_web/logs_live_test.exs test/ssh_client_web/settings_live_test.exs test/ssh_client_web/lock_live_test.exs`
Expected: PASS

- [ ] **Step 6: Commit changes**
```bash
git add lib/ssh_client_web/live/logs_live.ex lib/ssh_client_web/live/settings_live.ex lib/ssh_client_web/live/lock_live.ex
git commit -m "feat(ui): harmonize logs telemetry settings and lock screen"
```

---

### Task 6: Full Verification, Formatting, and Pre-flight Checks

**Files:**
- Check: All files modified across Tasks 1-5.

- [ ] **Step 1: Run code formatter**
Run: `mix format`
Run: `mix format --check-formatted`
Expected: PASS with 0 files changed or unformatted.

- [ ] **Step 2: Run full test suite**
Run: `mix test`
Expected: All tests pass.

- [ ] **Step 3: Run repository pre-flight script**
Run: `python scripts/check.py`
Expected: 100% PASS on zero-emoji checks, version synchronization, test scripts, and test suite.

- [ ] **Step 4: Commit any formatting or minor tweaks**
```bash
git add .
git commit -m "chore(ui): format code and finalize pre-flight validation"
```
