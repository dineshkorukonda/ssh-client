## ssh-client v0.0.1 (Beta)

Initial Beta release of ssh-client — an OTP-based, lightweight, high-performance SSH client and server manager with full-bleed LiveView terminal GUI for Windows and Linux.

---

### Binary Packages and Downloads

| Platform | Format | Package / Asset |
|---|---|---|
| Windows x64 | Single-File Installer | [ssh-client-setup-v0.0.1-windows-x64.exe](https://github.com/dineshkorukonda/ssh-client/releases/download/v0.0.1/ssh-client-setup-v0.0.1-windows-x64.exe) |
| Windows x64 | Portable ZIP Archive | [ssh-client-windows-x64.zip](https://github.com/dineshkorukonda/ssh-client/releases/download/v0.0.1/ssh-client-windows-x64.zip) |
| Linux x64 | Standalone Tarball | [ssh-client-linux-x64.tar.gz](https://github.com/dineshkorukonda/ssh-client/releases/download/v0.0.1/ssh-client-linux-x64.tar.gz) |
| Container (Docker) | GitHub Packages (GHCR) | `docker pull ghcr.io/dineshkorukonda/ssh-client:0.0.1-beta` |

---

### Core Capabilities

- Responsive Full-Bleed Terminal: High-performance xterm.js terminal integration with PTY streaming, bracketed paste mode, dynamic viewport resizing, and instant font adjustments.
- Command Autocomplete Palette: Fast fuzzy search across pre-built shell command categories (Zsh, System, Docker, Services, Network, Files) with one-click direct execution.
- Master Vault Encryption: Encrypted local credential store protecting passphrases, SSH keys, and server records.
- Native SFTP Explorer: Full directory tree browser, file uploads, file downloads, and remote file manipulation.
- OS Credential Store Integration: Windows Credential Manager and Linux libsecret backends with secure in-memory passphrase caching.
- SSH Config Importer: Seamless import from ~/.ssh/config with deduplication and custom fallback rules.
- Real-Time Service Control & Logs: Active daemon monitoring with background backoff, live log tailing, and systemd / Docker / PM2 service management.
- Editorial Stark UI: Minimalist, high-contrast dark aesthetic designed for developer focus without emoji clutter.

---

### Documentation & Links

- Repository: https://github.com/dineshkorukonda/ssh-client
- Documentation: https://ssh-client.dineshkorukonda.online
- Installation: https://ssh-client.dineshkorukonda.online/install
- Changelog: https://ssh-client.dineshkorukonda.online/changelog
