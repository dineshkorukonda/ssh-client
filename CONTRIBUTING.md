# Contributing Guidelines

Thank you for contributing to ssh-client. Please follow these guidelines to ensure consistency across the codebase.

## Commits

- Conventional Commits format: `type(scope): summary`
  - Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `perf`, `build`
  - Example: `feat(daemon): add per-server GenServer supervision`
- Imperative mood, lowercase summary, no period at end.
- No `Co-authored-by` trailers, ever — not for pairing, not for AI tools.
- No emojis in commit messages.
- Body explains why, not what, when the diff isn't self-explanatory.

## Issues

- Every feature or fix starts as an issue before code is written.
- Issue title follows the same type prefix as commits (`feat:`, `fix:`, etc.).
- Trivial fixes (typo, broken link) can skip the issue and go straight to PR.

## Pull Requests

- One PR per issue, linked via "Closes #N" in the PR description.
- Assign yourself to the PR before starting work, not after opening it.
- Keep PRs scoped to one issue — no drive-by unrelated changes.
- PR description: what changed, why, how it was tested.
- Must pass CI before merge.
- No emojis in PR titles or descriptions.
- Squash merge, so the final commit message follows the Conventional Commits rule above regardless of intermediate commit history.

## Code Style

- Small, single-responsibility functions/modules.
- No dead code, no commented-out code left in.
- Explicit error handling, no silent failures/swallowed errors.
- Descriptive names over comments explaining what code does.
- Comments explain why, not what.

## Releases & Versioning (0.0.x Beta Lifecycle)

- Every functional update or milestone must be reflected in the release pipeline and versioning (`0.0.1`, `0.0.2`, `0.0.x`).
- Version synchronization is mandatory across all version-bearing files:
  - `mix.exs` (`version: "0.0.x"`)
  - `windows/installer.iss` (`#define AppVersion "0.0.x"`)
  - `lib/ssh_client/updater.ex` (`@current_version "0.0.x"`)
  - `RELEASE_NOTES.md` (root release notes updated per release)
  - `CHANGELOG.md` (detailed feature & bugfix log)
  - `web/` landing pages (`web/index.html`, `web/install/index.html`, `web/changelog/index.html`)
- All releases must produce and publish cross-platform artifacts:
  - Windows x64 single-file installer (`ssh-client-setup-v0.0.x-windows-x64.exe`)
  - Windows x64 portable archive (`ssh-client-windows-x64.zip`)
  - Linux x64 standalone tarball (`ssh-client-linux-x64.tar.gz`)
  - Container image published to GitHub Packages (`ghcr.io/dineshkorukonda/ssh-client:0.0.x` and `:latest`)
- Releases must always be marked with `make_latest: true` to ensure the release is featured on the GitHub repository homepage.

## Before Implementing

- Check official documentation for the relevant tool/library before writing code against it (Elixir/OTP docs, Phoenix LiveView docs) — don't guess APIs or schemas from memory.
- If Superpowers (`obra/superpowers-marketplace`) is installed, use its brainstorming/planning skill before starting a non-trivial feature, and its systematic-debugging skill when investigating a bug, rather than jumping straight to a fix.

## No Emojis

- Anywhere: commits, PRs, issues, code comments, UI labels, release notes, README, CHANGELOG, and landing pages. Follow the editorial stark aesthetic at all times.
