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

## 2. Strict Aesthetic Rules: No Emojis
- Do not use emojis anywhere in this project:
  - No emojis in code, variable names, or comments
  - No emojis in UI buttons, tabs, notifications, or LiveView templates
  - No emojis in commit messages or pull request titles/descriptions
  - No emojis in `RELEASE_NOTES.md`, `CHANGELOG.md`, `README.md`, or the landing website
- Adhere strictly to the editorial stark dark aesthetic (monochrome, precise typography, subtle red/blue accents).

## 3. Architecture & Code Style
- Follow Elixir/OTP and Phoenix LiveView best practices.
- Favor small, focused modules with explicit pattern matching and error handling.
- Use native credential storage (Windows Credential Manager / Linux libsecret) with Master Vault encryption for sensitive data.
- Run tests (`mix test`) and verify formatting (`mix format`) before submitting commits.
