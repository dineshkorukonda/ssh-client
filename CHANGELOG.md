# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.2] - 2026-09-06

### Added
- **In-App Self-Updater**: Full in-app update management within `SettingsLive` and navigation. Downloads release payload in the background with live progress tracking (`0% -> 100%`) and automatically executes the Windows Setup installer (`.exe`) or opens the release directory.
- **Multi-Engine Update Fallback**: Added secondary (`curl`) and tertiary (PowerShell `Invoke-RestMethod`) fetchers to `SSHClient.Updater` to ensure update checks succeed across all execution environments.
- **Platform Asset Auto-Detection**: Automatically determines optimal platform release asset (`.exe` for Windows, `.tar.gz` for Linux) for single-click updates.

### Fixed
- **Release ERTS Application Packaging**: Included `:inets`, `:ssl`, `:crypto`, `:public_key`, and `:runtime_tools` in `mix.exs` `extra_applications` and release definition, resolving `:inets.start/0 is undefined (module :inets is not available)` in standalone releases.
- **Update Parsing Resiliency**: Added defensive decoding with `:json` and `Jason` fallback for GitHub Releases payload.

---

## [0.0.1] - 2026-09-05

### Added
- **Native Erlang/OTP SSH Transport**: Direct `:ssh` engine replacing external binary calls (`:ssh_connection`, `:ssh_sftp`).
- **Authentication**: Native `:ssh` authentication callback supporting `publickey` (`id_ed25519`, `id_rsa`, custom paths), password, ssh-agent, and keyboard-interactive authentication with per-host priority order.
- **Host Key Verification**: Fingerprint diff verification on changed host keys with reject-by-default logic and interactive accept/reject flow.
- **Terminal Engine**: Embedded xterm.js terminal with Phoenix Channel bridge (`terminal:input`, `terminal:output`, `terminal:resize`), PTY resize, and bracketed paste mode.
- **Desktop Window Shell**: Cross-platform desktop window integration via `elixir-desktop` (WebView2 on Windows, WebKitGTK on Linux).
- **Web Interface**: Phoenix LiveView server list (`HostLive`), terminal page (`TerminalLive`), real-time telemetry metrics, and modal dialogs.
- **Host Management**:
  - `user@host:port` quick-add parser.
  - Automatic `~/.ssh/config` importer with host deduplication.
  - In-memory fuzzy search with word boundary ranking over hosts, addresses, and tags.
- **OS Keychain Integration**:
  - Windows Credential Manager integration via PowerShell / native API port.
  - Linux Secret Service (`libsecret`) integration via `secret-tool`.
  - In-memory-only decrypted passphrase cache that clears on session termination.
- **Infrastructure Monitoring & Ops**:
  - Focus-aware polling engine for CPU, RAM, disk, and load average with idle backoff.
  - Remote service manager for `systemd` units, `Docker` containers, and `PM2` processes with confirmation dialogs.
  - Remote log tailing viewer for `journalctl` and system logs.
  - Cross-platform desktop notification router with fallback.
- **Master Vault Encryption (`SSHClient.Vault`)**: PBKDF2 (100,000 iterations) and AES-256-GCM encrypted local storage for credentials, keys, and passphrases with auto-lock and master password flow.
- **Native Remote SFTP Explorer (`SSHClient.SFTP` / `SFTPHostLive`)**: High-performance remote directory browser over OTP `:ssh_sftp` with directory breadcrumbs, inline text/config editor, file permissions, and directory creation/deletion.
- **Multi-Tab Terminal Session Manager (`TerminalLive`)**: Full-bleed xterm.js terminal supporting concurrent background PTY sessions, instant tab switching, terminal output preservation, and font scaling.
- **Command Autocomplete Palette**: Quick fuzzy-search command palette categorized for Zsh, Docker, System, Services, Network, and File utilities with direct one-click execution.
- **Real-Time Infrastructure Metric Gauges**: CPU, Memory, and Disk progress gauges with responsive warning/critical threshold color transitions.
- **Header Beta Badge & Editorial Stark UI**: Clean monochrome theme with high-contrast typography, Beta header badge, and strict zero-emoji interface compliance.
- **Automated Packaging & Release Pipeline**:
  - CI test matrix across `windows-latest` and `ubuntu-latest` with Docker OpenSSH integration tests.
  - Automated `mix release` packaging for Windows x64 (`.exe` single-file installer and `.zip` portable archive) and Linux x64 (`.tar.gz`).
  - Automated container image publishing to GitHub Packages (`ghcr.io/dineshkorukonda/ssh-client`).
  - Automated GitHub Releases on tag push with `make_latest: true`.
- **Minimalist Web Landing Page**: Zero-build technical landing site in `/web` with terminal specs, architecture breakdown, install instructions, and changelog.

### Fixed
- Resolved cross-platform socket API fallback for Windows named pipe / TCP vs Linux Unix domain sockets.
- Corrected host key verification callback to accept character list hostnames from Erlang `:ssh`.
- Stripped UTF-8 BOM characters across codebase for strict POSIX and Elixir compiler compatibility.
- Fine-tuned 2-character word boundary matching in fuzzy search engine.

### Changed
- Project renamed from `omarchy-server` to `ssh-client` (`:ssh_client` app, `SSHClient.*` namespace).
- Stripped Omarchy/QML desktop bar dependencies in favor of cross-platform LiveView + `elixir-desktop`.

---

## [0.1.0] - Prior History (`omarchy-server`)
- Historical releases originated as `omarchy-server`, an agentless SSH monitoring daemon and QML bar widget for Omarchy/Hyprland on Linux.
- Included Unix domain socket API, multi-target monitoring, init-system inspection (systemd, docker, pm2), and PTY-backed terminal daemon.
