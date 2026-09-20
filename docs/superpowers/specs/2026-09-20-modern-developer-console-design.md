# Design Specification - Modern Developer Console Architecture & Layout Redesign

## 1. Overview & Objective
Redesign the application layout structure, navigation shell, typography, spacing hierarchy, and interaction surfaces across all primary views (`Hosts`, `Terminal`, `SFTP`, `Logs`, `Settings`, and `Vault Lock`).
The target archetype is a **Modern Developer Console**: an integrated, sleek IDE-style interface featuring a unified persistent topbar (breadcrumbs, global search trigger, system health metrics, quick actions), a collapsible left navigation sidebar, standardized page headers, and maximized workspace canvases for Terminal and SFTP.

Strictly complies with [`AGENTS.md`](file:///C:/Users/dines/Developer/ssh-client/AGENTS.md) (zero emojis, monochrome editorial stark dark aesthetic with high contrast, semantic Phoenix LiveView components, and full test matrix).

---

## 2. Core Shell & Component Architecture

### 2.1 Unified `app_shell` (`lib/ssh_client_web/core_components.ex`)
- **Global Header / Topbar**:
  - Left: App logo (`>_ ssh-client`), version badge (`v0.0.52 BETA`), and interactive breadcrumbs (`ssh-client` / `Section` / `Target Host`).
  - Center/Right: Universal Search Trigger (`Ctrl+K` Command Palette), Reachability pill (`X/Y online`), Theme toggle, and Master Vault Lock button.
- **Left Navigation Sidebar**:
  - Sleek collapsible sidebar (`Hosts`, `Terminal`, `SFTP`, `Logs`, `Settings`).
  - Active tab indicator styling with high-contrast active state and subtle hover.
  - Collapse/expand toggle button with persistent state.
- **Main Canvas**:
  - Flex container with dynamic layout support:
    - Default scrollable padded layout (`p-6 md:p-8 max-w-7xl mx-auto`) for `Hosts`, `Logs`, and `Settings`.
    - Full-bleed edge-to-edge layout (`h-full w-full p-0 overflow-hidden`) for `Terminal` and `SFTP` to maximize working screen real-estate.

### 2.2 Reusable Layout Primitives (`core_components.ex`)
- `<.page_header title={...} subtitle={...}>`: Standardized header banner with uniform font sizes, tracking, and slots for action button bars.
- `<.console_toolbar>`: Reusable button group component for search inputs, import triggers, filters, and action buttons.
- `<.modal>`: Harmonized modal overlay with consistent backdrop blur (`bg-black/80 backdrop-blur-xs`), keyboard escape handlers, and unified action footers.

---

## 3. Subpage Redesign Details

### 3.1 Hosts Dashboard (`lib/ssh_client_web/live/host_live.html.heex`)
- Standardized `<.page_header>` with search filter, `Import ~/.ssh/config`, `Poll All`, `Save Workspace`, and `Add Server`.
- Refined High-Density Host Cards:
  - Header: Online/offline pulse dot, host name/alias, port pill.
  - Body: User & hostname display, jump host indicator, latency ping.
  - Action footer: Quick actions (`SFTP`, `Connect Terminal`, `Edit`, `Delete`) aligned uniformly.
- Re-architectured Workspaces and Active Port Forwarding panels with clean monospace tables.

### 3.2 Terminal Canvas (`lib/ssh_client_web/live/terminal_live.ex`)
- Server Selection Picker: Converted into the standardized card grid matching the Hosts dashboard.
- Active Session Workspace:
  - Top Toolbar: Multi-tab bar with active tab highlights, split pane controls (`Split Right`, `Split Down`), clear screen, font size adjustment, shortcuts modal button (`?`), and connection status badge.
  - Multi-Pane Terminal Grid: High-contrast border separators between active and inactive split panes.
  - Floating Quick Command Drawer / Snippet Bar: Non-obtrusive, keyboard-navigable command palette.

### 3.3 SFTP File Explorer (`lib/ssh_client_web/live/sftp_live.ex`)
- Server Selection Picker: Unified with Hosts & Terminal pickers.
- Dual-Pane Workspace:
  - Side-by-side local and remote panes with consistent header bars, path navigation breadcrumbs, and quick-jump links (`/var/www`, `/etc`, `/tmp`, `/root`).
  - Clear visual drop zones for drag-and-drop file transfers.
  - Bottom Transfer Queue Dock: Enhanced status bar with transfer progress bar, live throughput (`KB/s`, `MB/s`), remaining `ETA`, and cancel/retry controls.
  - Inline Code Editor Modal: Clean monospace syntax container with line numbering gutter and save/close actions.

### 3.4 Activity & Telemetry Logs (`lib/ssh_client_web/live/logs_live.ex`)
- Standardized `<.page_header>` with log stream controls (`Clear`, `Refresh`).
- Monospace Log Table:
  - High-density rows with timestamp, severity badges (`INFO`, `WARN`, `ERROR`), source host, and message text.
  - Slide-out or modal log detail inspector for expanded payloads and stack traces.

### 3.5 Settings & Diagnostics (`lib/ssh_client_web/live/settings_live.ex`)
- Sidebar/Tabbed layout for settings categories (`General`, `SSH Keys`, `Known Hosts`, `Updates`, `Diagnostics`).
- High-contrast cards for key discovery, updater checks, and diagnostic JSON export.

### 3.6 Vault Lock Screen (`lib/ssh_client_web/live/lock_live.ex`)
- Clean, centered developer-console aesthetic card with top brand mark, password inputs, error callouts, and reset confirmation dialog.

---

## 4. Verification & Testing Strategy
- **Unit & Helper Tests**: Verify all component render functions and helpers (`format_speed`, `format_eta`, `count_editor_lines`, `app_shell`).
- **LiveView Mount & Render Assertions**: Verify that all routes (`/`, `/terminal`, `/terminal/:id`, `/sftp`, `/sftp/:id`, `/logs`, `/settings`, `/lock`) render the new shell without warnings or missing assigns.
- **Pre-flight Check**: Run `mix format --check-formatted` and `python scripts/check.py` to guarantee zero-emoji compliance and 100% passing tests across the entire test suite.
