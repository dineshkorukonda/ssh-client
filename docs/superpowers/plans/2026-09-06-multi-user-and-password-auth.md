# Multi-User Accounts & Password Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable connecting to SSH servers with password authentication, saving passwords in OS Keychain, and supporting multiple user accounts per server.

**Architecture:** Extend `SSHClient.Config.Server` schema with `users: [String.t()]` and `default_auth_method`; integrate `SSHClient.Keychain` for credential lookup and persistence; create a connection-time user & auth modal in `HostLive`; wire credentials into `TerminalLive` and `SFTPLive`.

**Tech Stack:** Elixir/OTP, Phoenix LiveView, Erlang `:ssh`, OS Keychain (`SSHClient.Keychain`).

**Spec:** `docs/superpowers/specs/2026-09-06-multi-user-and-password-auth-design.md`

## Global Constraints
- Zero emojis anywhere in code, comments, UI, or commit messages.
- Clean editorial stark dark aesthetic (`#050505` bg, `#1f1f1f` borders, red/blue accents).
- Pass all automated release checks (`sync_release.py --check`, `--emoji-check`, `test_sync_release.py`).
- Maintain full unit and smoke test coverage.

---

### Task 1: Server Config Multi-User & Auth Schema Extension
- [ ] Write unit tests in `test/ssh_client/config/server_test.exs` for `users` parsing, string-to-list normalization, and `default_auth_method`.
- [ ] Update `SSHClient.Config.Server` struct definition and `from_map/1` to parse `users` and `default_auth_method`.
- [ ] Verify test suite and commit.

### Task 2: Keychain Credential Integration in SSH & Terminal
- [ ] Add unit tests in `test/ssh_client/keychain_test.exs` for account-specific credential storage (`user@server_id`).
- [ ] Enhance `SSHClient.SSH` and `SSHClient.SSH.PTYSession` to accept `user` and `password` overrides at connect time and lookup Keychain credentials if not passed in memory.
- [ ] Verify tests and commit.

### Task 3: HostLive Connection-Time User & Password Modal
- [ ] Add LiveView tests for connect modal rendering, user switching, and password form submission in `test/ssh_client_web/host_live_test.exs`.
- [ ] Implement `connect_modal` state, user selector, auth toggle, password input, and "Remember in Keychain" handling in `lib/ssh_client_web/live/host_live.ex`.
- [ ] Connect modal actions to trigger `/terminal/:id?user=...` and `/sftp/:id?user=...`.
- [ ] Verify zero emoji violations and commit.

### Task 4: TerminalLive & SFTPLive User / Credential Query Parameter Support
- [ ] Update `TerminalLive` and `SFTPLive` `handle_params/3` to read `user` and `auth` query params.
- [ ] Forward resolved user and credentials to session startup.
- [ ] Add route smoke assertions for parameter passing.
- [ ] Verify tests and commit.

### Task 5: Add Server Modal Multi-User Field Support
- [ ] Update Add/Edit Server form in `HostLive` to allow entering comma-separated additional users and selecting default auth method.
- [ ] Update `ServerManager.add_server` handling if needed.
- [ ] Verify tests and commit.

### Task 6: Final Verification & PR Lifecycle
- [ ] Run `python scripts/sync_release.py --check`
- [ ] Run `python scripts/sync_release.py --emoji-check`
- [ ] Run `python scripts/test_sync_release.py -v`
- [ ] Push branch `feat/multi-user-and-password-auth` and create PR.
- [ ] Monitor CI checks to green completion.
