# Design Specification: Shadcn Dual-Theme UI & Layout Revamp

- **Author**: Antigravity & Dinesh Korukonda
- **Date**: 2026-09-07
- **Target Release**: v0.0.22
- **Status**: Approved

---

## 1. Overview & Objectives

This specification outlines the complete overhaul of `ssh-client`s user interface. The redesign replaces previous bespoke layouts with the **shadcn/ui dashboard design system**, supporting full **Dual-Theme (Dark Zinc & Clean White Light)** capabilities, a unified top-bar navigation layout, modern data tables, stat overview cards, and 100% precompiled static CSS performance with zero client-side JIT overhead.

---

## 2. Design System & Theme Tokens

### 2.1 CSS Variables & Palette Matrix

We define custom semantic CSS variables for both light and dark modes in `assets/css/app.css` and `tailwind.config.js`:

| Token | Dark Zinc Theme (`[data-theme="dark"]` / `.dark`) | Light Theme (`[data-theme="light"]` / `.light`) |
| :--- | :--- | :--- |
| `--background` | `#09090b` (zinc-950) | `#ffffff` (pure white) |
| `--card` | `#121215` / `#18181b` (zinc-900) | `#ffffff` (white with border) |
| `--card-foreground` | `#fafafa` (zinc-50) | `#09090b` (zinc-950) |
| `--popover` | `#18181b` | `#ffffff` |
| `--popover-foreground` | `#fafafa` | `#09090b` |
| `--primary` | `#fafafa` (pure stark white) | `#09090b` (pure stark dark) |
| `--primary-foreground` | `#09090b` (zinc-950) | `#fafafa` (zinc-50) |
| `--secondary` | `#27272a` (zinc-800) | `#f4f4f5` (zinc-100) |
| `--secondary-foreground`| `#fafafa` (zinc-50) | `#09090b` (zinc-950) |
| `--muted` | `#27272a` (zinc-800) | `#f4f4f5` (zinc-100) |
| `--muted-foreground` | `#a1a1aa` (zinc-400) | `#71717a` (zinc-500) |
| `--accent` | `#27272a` | `#f4f4f5` |
| `--accent-foreground` | `#fafafa` | `#09090b` |
| `--destructive` | `#ef4444` (red-500) | `#dc2626` (red-600) |
| `--destructive-foreground` | `#ffffff` | `#ffffff` |
| `--success` | `#10b981` (emerald-500) | `#059669` (emerald-600) |
| `--border` | `#27272a` (zinc-800) | `#e4e4e7` (zinc-200) |
| `--input` | `#27272a` (zinc-800) | `#e4e4e7` (zinc-200) |
| `--ring` | `#d4d4d8` (zinc-300) | `#18181b` (zinc-900) |

### 2.2 Aesthetic Rules (Rule 3 Compliance)
- **Zero Emojis**: All icons are clean inline SVGs (lucide/heroicon style). No emojis anywhere in code, templates, or commits.
- **Typography**: Primary font `Poppins` and monospace font `JetBrains Mono`.
- **Border Radii**: Uniform `rounded-lg` (0.5rem) on cards, `rounded-md` (0.375rem) on buttons/inputs, and `rounded-full` on badges.

---

## 3. Structural Layout & Navigation

### 3.1 Top App Header (`root.html.heex` & `app.html.heex`)
The global header spans the full width (`h-14 border-b border-border bg-card/60 backdrop-blur-md px-6`):
- **Brand Area (Left)**: App icon svg, `ssh-client` bold title, and `v0.0.22 Beta` badge.
- **Navigation Tabs (Center)**: Segmented pill container (`bg-muted p-1 rounded-lg border border-border`):
  1. `Hosts` (with dynamic online/total indicator)
  2. `Terminal` (with active session tab indicator)
  3. `SFTP Explorer`
  4. `Activity Logs`
  5. `Settings`
- **Utility Actions (Right)**:
  - Online nodes status badge (`2/2 Reachable`)
  - Theme Toggle Button (`Sun / Moon` SVG icon, toggles dark/light)
  - Master Key Vault status pill & Lock button

### 3.2 Theme Switcher & Storage
- State stored in `localStorage.getItem('ssh_client_theme')` (`'dark'` or `'light'`).
- Immediately applied via head script to avoid flash-of-unstyled-theme:
  ```javascript
  const theme = localStorage.getItem('ssh_client_theme') || 'dark';
  document.documentElement.setAttribute('data-theme', theme);
  if (theme === 'dark') document.documentElement.classList.add('dark');
  else document.documentElement.classList.remove('dark');
  ```
- Dispatches event `ssh-client:theme-changed` to update running `xterm.js` terminals dynamically.

---

## 4. Component & View Specifications

### 4.1 Host Management Dashboard (`lib/ssh_client_web/live/host_live.ex`)
- **4 Top Stat Overview Cards (Shadcn Stat Card Style)**:
  1. *Total Servers*: Large bold count, subtext with server distribution.
  2. *Reachable & Polling*: Active healthchecks ratio with live pulsing status dot.
  3. *Average CPU Load*: Aggregate percentage with dynamic progress bar.
  4. *Memory & Network*: Telemetry metrics summary.
- **Sub-Header Toolbar**:
  - Filter input (`Filter servers by name, tag, or IP...`)
  - Filter category buttons (`All`, `Production`, `Staging`)
  - Quick action buttons (`+ Add Server`, `Poll All`, `Broadcast`)
- **Host Data Grid / Table**:
  - Responsive table with subtle header borders, clean row hover highlights, monospace host addresses, status dots, latency badges, and quick-action dropdowns/buttons (`SSH Connect`, `SFTP`, `Edit`, `Delete`).
- **Modals**:
  - Redesigned `Add Host`, `Edit Host`, and `Connect` modals using Shadcn dialog styles with dark/light form inputs.

### 4.2 Terminal Workspace (`lib/ssh_client_web/live/terminal_live.ex`)
- Multi-tab session switcher across the top.
- Full-bleed xterm container styled with matching border tokens.
- Dynamic theme synchronizer matching xterm background/foreground to active theme.

### 4.3 Remote SFTP Explorer (`lib/ssh_client_web/live/sftp_live.ex`)
- Breadcrumb navigation path bar.
- File explorer table with file type icons, human-readable file sizes, modification timestamps, permissions, and upload/download toolbar.

### 4.4 Telemetry & Activity Logs (`lib/ssh_client_web/live/logs_live.ex`)
- Clean log stream with severity badges (`INFO`, `WARN`, `ERROR`), search filter, auto-scroll toggle, and copy-all button.

### 4.5 Master Vault & Settings (`lib/ssh_client_web/live/lock_live.ex`, `settings_live.ex`)
- Minimal centered keycard for vault unlocking and setup with PBKDF2 encryption badge.
- Structured diagnostics and updater panels in settings.

---

## 5. Performance & Build Pipeline

1. **Asset Pipeline**:
   - `package.json` + `tailwind.config.js` with full dark/light theme definitions.
   - `npm run build:css` compiles `assets/css/app.css` into `priv/static/css/app.css`.
2. **Zero Runtime JIT Overhead**:
   - No external Tailwind runtime scripts or `MutationObserver` overhead.
   - 0ms client-side CPU consumption.
3. **Pre-flight & CI Verification**:
   - `python scripts/check.py` auditing zero emojis, version sync, release tests, and 239 ExUnit tests.

---

## 6. Verification Plan

1. **Unit & Integration Tests**:
   - Run `mix test` to ensure all 239 tests pass.
2. **Visual & Theme Switching Verification**:
   - Verify dark mode rendering against shadcn zinc guidelines.
   - Verify light mode rendering with crisp high-contrast white background and dark text.
   - Verify theme toggle button persists across page reloads and updates xterm.js theme.
3. **CI & Release Automation**:
   - Open PR on feature branch with labels and assignee.
   - Monitor CI pipeline and post-merge automated release.
