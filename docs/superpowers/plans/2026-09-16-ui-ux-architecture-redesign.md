# UI/UX & Backend Architecture Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clean up the architecture of `ssh-client`, extract bloated inline JavaScript hooks from `root.html.heex` into modular static files, expand `core_components.ex` with reusable UI elements, extract shared `on_mount` live auth guards, and polish UI/UX hierarchy across all LiveViews.

**Architecture:** 
1. Extract JavaScript hooks (`TerminalHook`, `TerminalPane`, `DualPaneSFTPHook`, `CommandPaletteHook`, `ThemeHook`) from inline `<script>` blocks in `root.html.heex` into `priv/static/js/hooks/*.js` bundled/loaded via `priv/static/js/app.js`.
2. Introduce a shared `SSHClientWeb.LiveAuth` `on_mount` hook to eliminate duplicated `Vault.unlocked?()` checks across all LiveViews.
3. Expand `core_components.ex` to provide standardized modal, form field, breadcrumb, card, and empty state components.
4. Clean up `host_live.html.heex` and other templates to use the new standardized components.
5. Fix CSS token alignment between Tailwind and DaisyUI with safelisted status classes.
6. Synchronize version numbers across files to `0.0.39`.

**Tech Stack:** Phoenix LiveView 1.0, Tailwind CSS, DaisyUI, xterm.js, Elixir/OTP.

**Spec:** `C:\Users\dines\.gemini\antigravity\brain\2adf89ba-135d-43ad-ba40-d1047ddd0155\implementation_plan.md`

## Global Constraints
- **Zero Emojis**: Strictly no emojis anywhere in code, comments, templates, logs, or commit messages (AGENTS.md Rule 3).
- **Dark & Light dual theme**: Must preserve full dark/light monochrome support.
- **Pass all automated checks**: `mix test` must pass (353+ tests) and `python scripts/check.py` must succeed.

---

### Task 1: Extract JS Hooks from `root.html.heex` into Static Files

**Files:**
- Create: `priv/static/js/hooks/terminal_hook.js`
- Create: `priv/static/js/hooks/terminal_pane_hook.js`
- Create: `priv/static/js/hooks/sftp_hook.js`
- Create: `priv/static/js/hooks/command_palette_hook.js`
- Create: `priv/static/js/hooks/theme_hook.js`
- Create: `priv/static/js/app.js`
- Modify: `lib/ssh_client_web/layouts/root.html.heex`

**Interfaces:**
- Produces: `window.TerminalHook`, `window.TerminalPane`, `window.DualPaneSFTPHook`, `window.CommandPaletteHook`, `window.ThemeHook` and `window.liveSocket` initialized in `priv/static/js/app.js`.
- Consumes: xterm.js global `Terminal`, `FitAddon`, `SearchAddon` and Phoenix LiveView client `Phoenix.Socket`, `LiveView.LiveSocket`.

- [ ] **Step 1: Create hook modules under `priv/static/js/hooks/`**
- [ ] **Step 2: Create `priv/static/js/app.js`**
- [ ] **Step 3: Update `root.html.heex`**
- [ ] **Step 4: Verify with test suite**
- [ ] **Step 5: Commit**

---

### Task 2: Implement Shared `SSHClientWeb.LiveAuth` on_mount Hook

**Files:**
- Create: `lib/ssh_client_web/live_auth.ex`
- Modify: `lib/ssh_client_web/live/host_live.ex`
- Modify: `lib/ssh_client_web/live/terminal_live.ex`
- Modify: `lib/ssh_client_web/live/sftp_live.ex`
- Modify: `lib/ssh_client_web/live/settings_live.ex`
- Modify: `lib/ssh_client_web/live/logs_live.ex`
- Test: `test/ssh_client_web/live/lock_live_test.exs`

- [ ] **Step 1: Create `lib/ssh_client_web/live_auth.ex`**
- [ ] **Step 2: Update LiveViews to use `on_mount {SSHClientWeb.LiveAuth, :require_unlocked}`**
- [ ] **Step 3: Run existing lock and liveview tests**
- [ ] **Step 4: Commit**

---

### Task 3: Expand `SSHClientWeb.CoreComponents` Component Library

**Files:**
- Modify: `lib/ssh_client_web/core_components.ex`
- Test: `test/ssh_client_web/core_components_test.exs`

- [ ] **Step 1: Write test for new core components in `test/ssh_client_web/core_components_test.exs`**
- [ ] **Step 2: Implement `<.modal>`, `<.empty_state>`, `<.breadcrumb>`, and updated `<.top_navigation>`**
- [ ] **Step 3: Run `mix test test/ssh_client_web/core_components_test.exs`**
- [ ] **Step 4: Commit**

---

### Task 4: Template Clean-up & UI/UX Layout Refresh

**Files:**
- Modify: `lib/ssh_client_web/live/host_live.html.heex`
- Modify: `assets/css/app.css`
- Modify: `tailwind.config.js`

- [ ] **Step 1: Group toolbar actions and replace raw modal wrappers in `host_live.html.heex` with `<.modal>`**
- [ ] **Step 2: Add safelist classes to `tailwind.config.js` for dynamic status badges**
- [ ] **Step 3: Rebuild CSS via `npm run build:css`**
- [ ] **Step 4: Run test suite**
- [ ] **Step 5: Commit**

---

### Task 5: Version Synchronization & Pre-flight Verification

**Files:**
- Modify: `mix.exs` -> `version: "0.0.39"`
- Modify: `windows/installer.iss` -> `#define AppVersion "0.0.39"`
- Modify: `lib/ssh_client/updater.ex` -> `@current_version "0.0.39"`
- Modify: `web/index.html`, `web/install/index.html`, `web/changelog/index.html`

- [ ] **Step 1: Update version numbers to 0.0.39**
- [ ] **Step 2: Run verification scripts (`python scripts/check.py`)**
- [ ] **Step 3: Run full `mix test`**
- [ ] **Step 4: Commit**
