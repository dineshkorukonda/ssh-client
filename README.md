# ssh-client

A lightweight, cross-platform (Windows + Linux) desktop SSH client with agentless remote host monitoring, interactive terminal sessions, secure credential management, and remote service control. Built on Elixir/OTP, Erlang's native `:ssh` application, and Phoenix LiveView with xterm.js.

---

## Highlights & Non-Negotiables

- **No forced accounts, cloud sync, or telemetry**: 100% offline-first and self-contained. Your server configurations and keys never leave your machine.
- **Secure OS credential storage**: Credentials never touch plaintext config files. Passwords and passphrases are resolved at connect time via Windows Credential Manager (`cmdkey` / Win32 API) or Linux Secret Service (`secret-tool` / `libsecret`), with a protected in-memory RAM cache.
- **Deterministic, plain-language errors**: Exact diagnostics for every SSH failure mode (DNS resolution failure, timeout, host key mismatch, rejected key, exhausted auth methods, permission denied) with actionable remediation steps.
- **Resource discipline**: Zero background polling overhead when minimized or out of focus. Idle hosts do not hold open shell channels.
- **Native Erlang `:ssh` transport**: Pure BEAM network transport without relying on external OpenSSH binaries or shelled commands. Works identically across Windows and Linux.
- **Dual UI surfaces**: Rich native desktop window powered by Phoenix LiveView & xterm.js, plus a lightweight CLI / TUI for terminal-native environments.

---

## Installation & Setup

### Windows

#### 1. Pre-built Release
Download `ssh-client-windows-x64.zip` from the latest GitHub Release or CI workflow artifacts:
1. Extract the `.zip` to your desired directory (e.g., `C:\Program Files\ssh-client` or `%LOCALAPPDATA%\ssh-client`).
2. Run `bin\ssh_client.bat start` or launch the desktop shortcut.

#### 2. From Source
**Prerequisites**:
- [Erlang/OTP 27+](https://www.erlang.org/downloads)
- [Elixir 1.18+](https://elixir-lang.org/install.html)

```powershell
# Clone the repository
git clone https://github.com/dineshkorukonda/ssh-client.git
cd ssh-client

# Install dependencies and compile
mix deps.get
mix compile

# Run tests
mix test

# Start the application
iex -S mix
```

---

### Linux (Ubuntu, Debian, Arch, Fedora)

#### 1. Pre-built Release
Download `ssh-client-linux-x64.tar.gz` from the latest GitHub Release or CI workflow artifacts:
```bash
tar -xzf ssh-client-linux-x64.tar.gz -C /opt/ssh-client
/opt/ssh-client/bin/ssh_client start
```

#### 2. System Requirements (Linux)
- For credential storage: `libsecret-tools` or any FreeDesktop Secret Service daemon (e.g. GNOME Keyring, KWallet).
  ```bash
  # Debian/Ubuntu
  sudo apt install libsecret-tools

  # Fedora
  sudo dnf install libsecret

  # Arch Linux
  sudo pacman -S libsecret
  ```
- For desktop notifications: `notify-send` (`libnotify-bin` or `libnotify`).

#### 3. From Source
```bash
git clone https://github.com/dineshkorukonda/ssh-client.git
cd ssh-client

mix deps.get
mix compile
mix test

# Start the application
iex -S mix
```

---

## Authentication Walkthrough

`ssh-client` supports all standard SSH authentication methods with per-host custom ordering:

### 1. SSH Public Key Authentication (Recommended)
- Supports Ed25519, RSA, and ECDSA keys.
- If your private key is encrypted with a passphrase, `ssh-client` will securely prompt for it on first connection and cache it in RAM for the session.
- You can store passphrases permanently in your OS Keychain (Windows Credential Manager / Linux libsecret) so you are never prompted again.

### 2. Password Authentication
- Stored safely in the OS credential vault under the target host's identifier.
- Passwords are encrypted by your operating system's native keychain infrastructure.

### 3. Keyboard-Interactive (2FA / PAM)
- Supports multi-step challenge-response authentication (e.g., Google Authenticator, Duo MFA OTP tokens).
- Challenges are presented cleanly in the UI modal or terminal prompt.

---

## Host Management & Configuration

### Configuration File Locations
Configuration paths follow operating system standards:
- **Windows**: `%APPDATA%\ssh-client\config.yaml`
- **Linux**: `~/.config/ssh-client/config.yaml` (respects `$XDG_CONFIG_HOME`)

### OpenSSH Config Import
You can automatically import existing hosts from `~/.ssh/config` (or `%USERPROFILE%\.ssh\config`) with full deduplication and preserved identities:
- Automatically detects hostnames, users, ports, and identity files.
- Preserves per-host overrides without duplicating entries.

### Quick Add
Add a host instantly via the search bar or UI modal:
```text
user@192.168.1.100:22
```

---

## Terminal & Monitoring Features

- **Embedded xterm.js Terminal**: Full 256-color and 24-bit TrueColor support, bracketed paste mode, dynamic PTY resizing, and clipboard integration.
- **Agentless Host Telemetry**: Periodic CPU, memory, disk, and load monitoring executed via non-interactive SSH channels.
- **Service Management**: Inspect and control systemd services, Docker containers, and PM2 processes with safety confirmation dialogs.
- **Remote Log Viewer**: Live streaming tail of remote system and service logs.
- **Desktop Notifications**: Cross-platform system tray and notification center alerts for connection failures, service crashes, and high disk usage.

---

### Running the Test Suite
```bash
# Unit tests
mix test

# Integration tests with Docker SSH fixture
docker compose -f docker-compose.test.yml up -d --build
mix test test/integration --include integration
docker compose -f docker-compose.test.yml down
```

---

## License

MIT License - see [LICENSE](LICENSE) for details.
