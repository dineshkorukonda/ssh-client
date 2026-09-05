## ssh-client v0.0.2 (Beta)

Beta release v0.0.2 delivers an integrated in-app self-updater with live download progress streaming and automatic installer launching, packages missing Erlang/OTP `:inets` and `:ssl` runtime modules in the release distribution, and includes multi-tier fallback HTTP fetchers for reliable update checks.

---

### Binary Packages and Downloads

| Platform | Format | Package / Asset |
|---|---|---|
| Windows x64 | Single-File Installer | [ssh-client-setup-v0.0.2-windows-x64.exe](https://github.com/dineshkorukonda/ssh-client/releases/download/v0.0.2/ssh-client-setup-v0.0.2-windows-x64.exe) |
| Windows x64 | Portable ZIP Archive | [ssh-client-windows-x64.zip](https://github.com/dineshkorukonda/ssh-client/releases/download/v0.0.2/ssh-client-windows-x64.zip) |
| Linux x64 | Standalone Tarball | [ssh-client-linux-x64.tar.gz](https://github.com/dineshkorukonda/ssh-client/releases/download/v0.0.2/ssh-client-linux-x64.tar.gz) |
| Container (Docker) | GitHub Packages (GHCR) | `docker pull ghcr.io/dineshkorukonda/ssh-client:0.0.2` |

---

### Key Highlights in v0.0.2

- **In-App Self-Updater**: Integrated 1-click update flow inside Settings and navigation. Downloads release payload in the background with live progress tracking and triggers installer execution on Windows or tarball extraction on Linux.
- **Runtime Application Inclusions**: Bundled `:inets`, `:ssl`, `:crypto`, and `:public_key` applications into OTP release ERTS payload, eliminating `:inets.start/0 is undefined` errors in standalone releases.
- **Multi-Engine Update Fallback**: Multi-tier HTTP fetcher using `:httpc` primary, `curl` secondary, and PowerShell `Invoke-RestMethod` tertiary to guarantee update checks succeed in all operating environments.
- **Master Vault & Native SFTP Explorer**: Zero-plain-text storage with PBKDF2 (100k iterations) AES-256-GCM vault and high-performance remote SFTP file browser with inline text editor.
- **Editorial Stark Dark UI**: Zero-emoji monochrome interface with high-contrast typography, Beta header badge, and responsive gauges.

---

### Documentation & Links

- Repository: https://github.com/dineshkorukonda/ssh-client
- Documentation: https://ssh-client.dineshkorukonda.online
- Installation: https://ssh-client.dineshkorukonda.online/install
- Changelog: https://ssh-client.dineshkorukonda.online/changelog

