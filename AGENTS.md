# Agent Guidelines & Repository Rules

This document governs the coding, testing, release, and style rules for `ssh-client`. All automated agents and contributors must strictly adhere to these rules.

## 1. Versioning & Release Cadence (0.0.x Beta Lifecycle)
- Every major update, feature, or testing milestone must be reflected in the release pipeline and versioning (`0.0.1`, `0.0.2`, `0.0.x`, etc.).
- When bumping version, keep all version references strictly synchronized across:
  1. `mix.exs` -> `version: "0.0.x"`
  2. `windows/installer.iss` -> `#define AppVersion "0.0.x"`
  3. `lib/ssh_client/updater.ex` -> `@current_version "0.0.x"`
  4. `RELEASE_NOTES.md` -> Root release notes document (updated per release)
  5. `CHANGELOG.md` -> Detailed changelog
  6. `web/` landing site -> `web/index.html`, `web/install/index.html`, `web/changelog/index.html`
- Every release must publish:
  - Windows x64 single-file installer (`.exe`)
  - Windows x64 portable ZIP archive (`.zip`)
  - Linux x64 standalone tarball (`.tar.gz`)
  - Multi-platform container image to GitHub Packages (`ghcr.io/dineshkorukonda/ssh-client:0.0.x` and `:latest`)
- All releases created via GitHub Actions or CLI must be flagged with `make_latest: true` (or `--latest=true`) so they appear directly on the GitHub repository homepage under Releases.

## 2. Pull Request, CI & Release Bot Monitoring Rules
- Every change must go through a dedicated feature or bugfix branch and a GitHub Pull Request.
- Before and after merging PRs:
  1. **Monitor PR Checks**: Verify that all CI checks pass on the PR branch (`gh pr checks <number>`).
  2. **Branch Management**: Do NOT delete branches prematurely. Retain branch context until CI and release workflows have fully succeeded.
  3. **Monitor Post-Merge Release Bot**: Immediately after merging to `main`, check the automated `Release Bot` and `CI` workflow runs (`gh run list`, `gh run view <id>`). Verify that auto-bump, tagging, and asset build jobs complete successfully. If any failure occurs, diagnose and resolve it immediately.
- Run `python scripts/sync_release.py --check`, `python scripts/sync_release.py --emoji-check`, and `python scripts/test_sync_release.py` before submitting any PR.

## 3. Strict Aesthetic Rules: No Emojis
- Do not use emojis anywhere in this project:
  - No emojis in code, variable names, or comments
  - No emojis in UI buttons, tabs, notifications, or LiveView templates
  - No emojis in commit messages or pull request titles/descriptions
  - No emojis in `RELEASE_NOTES.md`, `CHANGELOG.md`, `README.md`, or the landing website
- Adhere strictly to the editorial stark dark aesthetic (monochrome, precise typography, subtle red/blue accents).

## 4. Testing & Code Quality Matrix
- Maintain a complete testing matrix for all features and fixes:
  1. **Unit Tests**: Test pure business logic, helpers, formatting, parsers, and data structures.
  2. **Smoke & Route Tests**: Test all LiveViews, routes, and layout mounts with standard callback assertions.
  3. **Regression Tests**: Every resolved bug must have a dedicated regression test reproducing and preventing the failure mode.
  4. **Integration Tests**: Test end-to-end SSH/SFTP connections, worker supervisors, and process lifecycles.
- Follow Elixir/OTP and Phoenix LiveView best practices.
- Favor small, focused modules with explicit pattern matching and defensive error handling (no unhandled nil dereferences).
