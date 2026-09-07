# Shadcn Dual-Theme UI & Layout Revamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete overhaul of `ssh-client` interface implementing the Shadcn dashboard design system with full dual-theme (Dark Zinc & Clean White Light) support, unified top bar navigation, modern stat cards, clean data tables, and precompiled static CSS.

**Architecture:** Tailwind CSS v3 + DaisyUI v4 precompiled into static `priv/static/css/app.css` with CSS custom properties supporting dynamic `data-theme="dark"` and `data-theme="light"`. LiveViews and root templates updated to use shadcn design tokens and responsive layouts.

**Tech Stack:** Elixir / Phoenix LiveView, Tailwind CSS v3, DaisyUI v4, xterm.js.

**Spec:** `docs/superpowers/specs/2026-09-07-shadcn-dual-theme-ui-revamp-design.md`

## Global Constraints

- Strict Zero-Emoji Rule: No emojis anywhere in code, comments, templates, commit messages, or PRs.
- Dual-Theme Support: Every component must render crisp in both `dark` (zinc-950/zinc-900) and `light` (white/zinc-100) modes.
- Performance: 100% precompiled static CSS in `priv/static/css/app.css` (no runtime compiler JS).
- Testing: All 239 existing tests must pass + add tests for theme toggling and live components.

---

### Task 1: Dual-Theme CSS Variables & Tailwind Configuration

**Files:**
- Modify: `tailwind.config.js`
- Modify: `assets/css/app.css`
- Modify: `priv/static/css/app.css`

**Interfaces:**
- Produces: CSS custom properties (`--background`, `--foreground`, `--card`, `--border`, `--primary`, `--muted`, `--accent`, etc.) supporting both `[data-theme="dark"]` / `.dark` and `[data-theme="light"]` / `.light`.

- [ ] **Step 1: Update `tailwind.config.js` with comprehensive theme tokens**

```javascript
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./lib/**/*.{ex,heex}",
    "./priv/static/**/*.js",
    "./web/**/*.{html,js}"
  ],
  darkMode: ["class", '[data-theme="dark"]'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Poppins', '-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'Roboto', 'sans-serif'],
        mono: ['JetBrains Mono', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'Monaco', 'Consolas', 'monospace'],
      },
      colors: {
        background: "hsl(var(--background) / <alpha-value>)",
        foreground: "hsl(var(--foreground) / <alpha-value>)",
        card: {
          DEFAULT: "hsl(var(--card) / <alpha-value>)",
          foreground: "hsl(var(--card-foreground) / <alpha-value>)",
        },
        popover: {
          DEFAULT: "hsl(var(--popover) / <alpha-value>)",
          foreground: "hsl(var(--popover-foreground) / <alpha-value>)",
        },
        primary: {
          DEFAULT: "hsl(var(--primary) / <alpha-value>)",
          foreground: "hsl(var(--primary-foreground) / <alpha-value>)",
        },
        secondary: {
          DEFAULT: "hsl(var(--secondary) / <alpha-value>)",
          foreground: "hsl(var(--secondary-foreground) / <alpha-value>)",
        },
        muted: {
          DEFAULT: "hsl(var(--muted) / <alpha-value>)",
          foreground: "hsl(var(--muted-foreground) / <alpha-value>)",
        },
        accent: {
          DEFAULT: "hsl(var(--accent) / <alpha-value>)",
          foreground: "hsl(var(--accent-foreground) / <alpha-value>)",
        },
        destructive: {
          DEFAULT: "hsl(var(--destructive) / <alpha-value>)",
          foreground: "hsl(var(--destructive-foreground) / <alpha-value>)",
        },
        border: "hsl(var(--border) / <alpha-value>)",
        input: "hsl(var(--input) / <alpha-value>)",
        ring: "hsl(var(--ring) / <alpha-value>)",
      },
    },
  },
  plugins: [
    require("daisyui")
  ],
  daisyui: {
    themes: [
      {
        dark: {
          "color-scheme": "dark",
          "primary": "#fafafa",
          "primary-content": "#09090b",
          "secondary": "#27272a",
          "secondary-content": "#fafafa",
          "accent": "#ef4444",
          "accent-content": "#ffffff",
          "neutral": "#18181b",
          "neutral-content": "#f4f4f5",
          "base-100": "#09090b",
          "base-200": "#121215",
          "base-300": "#18181b",
          "base-content": "#fafafa",
          "info": "#38bdf8",
          "info-content": "#09090b",
          "success": "#10b981",
          "success-content": "#ffffff",
          "warning": "#f59e0b",
          "warning-content": "#09090b",
          "error": "#ef4444",
          "error-content": "#ffffff",
        },
        light: {
          "color-scheme": "light",
          "primary": "#09090b",
          "primary-content": "#ffffff",
          "secondary": "#f4f4f5",
          "secondary-content": "#09090b",
          "accent": "#ef4444",
          "accent-content": "#ffffff",
          "neutral": "#f4f4f5",
          "neutral-content": "#09090b",
          "base-100": "#ffffff",
          "base-200": "#f4f4f5",
          "base-300": "#e4e4e7",
          "base-content": "#09090b",
          "info": "#0284c7",
          "info-content": "#ffffff",
          "success": "#059669",
          "success-content": "#ffffff",
          "warning": "#d97706",
          "warning-content": "#ffffff",
          "error": "#dc2626",
          "error-content": "#ffffff",
        }
      }
    ],
    base: true,
    styled: true,
    utils: true,
  }
}
```

- [ ] **Step 2: Update `assets/css/app.css` with CSS variables for Light & Dark modes**

```css
@tailwind base;
@tailwind components;
@tailwind utilities;

@layer base {
  :root,
  [data-theme="light"],
  .light {
    --background: 0 0% 100%;
    --foreground: 240 10% 3.9%;
    --card: 0 0% 100%;
    --card-foreground: 240 10% 3.9%;
    --popover: 0 0% 100%;
    --popover-foreground: 240 10% 3.9%;
    --primary: 240 5.9% 10%;
    --primary-foreground: 0 0% 98%;
    --secondary: 240 4.8% 95.9%;
    --secondary-foreground: 240 5.9% 10%;
    --muted: 240 4.8% 95.9%;
    --muted-foreground: 240 3.8% 46.1%;
    --accent: 240 4.8% 95.9%;
    --accent-foreground: 240 5.9% 10%;
    --destructive: 0 84.2% 60.2%;
    --destructive-foreground: 0 0% 98%;
    --border: 240 5.9% 90%;
    --input: 240 5.9% 90%;
    --ring: 240 5.9% 10%;
    --radius: 0.5rem;
  }

  [data-theme="dark"],
  .dark {
    --background: 240 10% 3.9%;
    --foreground: 0 0% 98%;
    --card: 240 10% 4.9%;
    --card-foreground: 0 0% 98%;
    --popover: 240 10% 4.9%;
    --popover-foreground: 0 0% 98%;
    --primary: 0 0% 98%;
    --primary-foreground: 240 5.9% 10%;
    --secondary: 240 3.7% 15.9%;
    --secondary-foreground: 0 0% 98%;
    --muted: 240 3.7% 15.9%;
    --muted-foreground: 240 5% 64.9%;
    --accent: 240 3.7% 15.9%;
    --accent-foreground: 0 0% 98%;
    --destructive: 0 62.8% 30.6%;
    --destructive-foreground: 0 0% 98%;
    --border: 240 3.7% 15.9%;
    --input: 240 3.7% 15.9%;
    --ring: 240 4.9% 83.9%;
  }
}

body {
  background-color: hsl(var(--background));
  color: hsl(var(--foreground));
  font-family: 'Poppins', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

/* Custom scrollbars */
::-webkit-scrollbar {
  width: 6px;
  height: 6px;
}
::-webkit-scrollbar-track {
  background: transparent;
}
::-webkit-scrollbar-thumb {
  background: hsl(var(--border));
  border-radius: 3px;
}
::-webkit-scrollbar-thumb:hover {
  background: hsl(var(--muted-foreground));
}

.font-mono {
  font-family: 'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
}
```

- [ ] **Step 3: Compile CSS via `npm run build:css`**
- [ ] **Step 4: Verify CSS generation and commit**

---

### Task 2: Global Root Header & Theme Switcher (`root.html.heex` & `app.html.heex`)

**Files:**
- Modify: `lib/ssh_client_web/layouts/root.html.heex`
- Modify: `lib/ssh_client_web/layouts/app.html.heex`

**Interfaces:**
- Produces: Shadcn top navbar with live tabs, theme toggle script, and toast alert container.

- [ ] **Step 1: Add dynamic theme toggle handler and xterm theme sync script in `root.html.heex`**
- [ ] **Step 2: Redesign top navigation bar with Shadcn segmented pills and Sun/Moon toggle**
- [ ] **Step 3: Redesign flash toasts in `app.html.heex` with Shadcn alert tokens**
- [ ] **Step 4: Recompile CSS and verify layout rendering**
- [ ] **Step 5: Commit changes**

---

### Task 3: Host Dashboard & Stat Cards Revamp (`host_live.ex`)

**Files:**
- Modify: `lib/ssh_client_web/live/host_live.ex`
- Test: `test/ssh_client_web/live/host_live_test.exs`

**Interfaces:**
- Produces: 4 Shadcn stat cards, search toolbar, clean data table with CPU/RAM gauges, and styled modals.

- [ ] **Step 1: Refactor stats header into 4 Shadcn metric cards with dual-theme border/background classes**
- [ ] **Step 2: Refactor host table and card grid with dual-theme tokens**
- [ ] **Step 3: Refactor Add/Edit Host and Connect Modals with Shadcn dialog tokens**
- [ ] **Step 4: Run `mix test test/ssh_client_web/live/host_live_test.exs`**
- [ ] **Step 5: Commit changes**

---

### Task 4: Terminal, SFTP, Logs & Vault Views Revamp

**Files:**
- Modify: `lib/ssh_client_web/live/terminal_live.ex`
- Modify: `lib/ssh_client_web/live/sftp_live.ex`
- Modify: `lib/ssh_client_web/live/logs_live.ex`
- Modify: `lib/ssh_client_web/live/settings_live.ex`
- Modify: `lib/ssh_client_web/live/lock_live.ex`

**Interfaces:**
- Produces: Consistent Shadcn dual-theme styling across all secondary LiveViews.

- [ ] **Step 1: Refactor Terminal LiveView tabs and status footer**
- [ ] **Step 2: Refactor SFTP LiveView explorer layout and file table**
- [ ] **Step 3: Refactor Logs LiveView streaming table and filter chips**
- [ ] **Step 4: Refactor Settings and Lock LiveView keycards**
- [ ] **Step 5: Recompile static CSS bundle with `npm run build:css`**
- [ ] **Step 6: Run full test suite `mix test`**
- [ ] **Step 7: Commit changes**

---

### Task 5: Pre-Flight Verification & Release

**Files:**
- Audit all files via `python scripts/check.py`

- [ ] **Step 1: Run `python scripts/check.py` to verify zero-emojis, version sync, and unit tests**
- [ ] **Step 2: Push feature branch and create GitHub Pull Request**
- [ ] **Step 3: Monitor CI workflow checks and merge to `main`**
- [ ] **Step 4: Monitor automated Release Bot and release pipeline**
