# Phase 1: Terminal Polish & Session Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve terminal reliability and UX by adding a built-in keyboard shortcuts cheat sheet modal, wiring seamless keyboard focus between tabs and split panes, and adding test coverage.

**Architecture:** Extend `TerminalLive` with a `show_shortcuts_modal` toggle (`?` / `Ctrl+Shift+?`), render a monochrome editorial modal listing all shortcuts, hook custom key handler navigation in `terminal_hook.js`, and verify zero emoji and clean CI test compliance.

**Tech Stack:** Phoenix LiveView, xterm.js, Elixir / OTP.

---

### Task 1: Terminal Keyboard Shortcuts Cheat Sheet Modal

**Files:**
- Modify: `lib/ssh_client_web/live/terminal_live.ex`
- Modify: `priv/static/js/hooks/terminal_hook.js`
- Test: `test/ssh_client_web/terminal_live_test.exs`

- [ ] Step 1: Add failing test for `toggle_shortcuts` and `close_shortcuts` events in `test/ssh_client_web/terminal_live_test.exs`
- [ ] Step 2: Implement `toggle_shortcuts` and `close_shortcuts` in `lib/ssh_client_web/live/terminal_live.ex` and update initial assigns
- [ ] Step 3: Add `Shortcuts` button in topbar and render editorial dark shortcuts modal in `terminal_live.ex`
- [ ] Step 4: Handle `?` and `Shift+?` key shortcuts in `terminal_hook.js` and `handle_key`
- [ ] Step 5: Run tests and pre-flight check (`python scripts/check.py`)
