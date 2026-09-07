# Design: Ephemeral Password Authentication & Automatic SSH Key Deployment (ssh-copy-id)

Date: 2026-09-07
Status: Proposed

## 1. Overview & Motivation

Storing plaintext passwords in configuration files or attempting to persist passwords through platform-specific Credential Managers (`cmdkey` on Windows, `secret-tool` on Linux) is prone to security risks, missing D-Bus services in headless/container environments, and read limitations on Windows.

Instead, `ssh-client` adopts a zero-disk credential approach:
1. **Ephemeral Passwords**: Passwords entered during quick-add or connection modals are kept in volatile process RAM (`PassphraseCache` / LiveView state) for the active session and are never written to disk or configuration files.
2. **Automated SSH Key Deployment (`ssh-copy-id`)**: When a user connects to a remote server with password authentication, `ssh-client` offers a one-click action to install the local public SSH key onto the remote host's `~/.ssh/authorized_keys`. Once installed, the host's configuration is automatically updated to use public key authentication for all future connections.

---

## 2. Architecture & Components

```
+-------------------------------------------------------------+
|                      ssh-client UI                          |
|  (HostLive / TerminalLive / QuickAdd Modal / Prompt Modal)  |
+------------------------------+------------------------------+
                               |
            +------------------+------------------+
            |                                     |
            v                                     v
+-----------------------+             +-----------------------+
|  SSH.KeyManager       |             |  SSH.KeyDeployer      |
|  - list_public_keys   |             |  - deploy_public_key  |
|  - get_default_key    |             |  - install script     |
|  - generate_key_pair  |             |  - update server cfg  |
+-----------+-----------+             +-----------+-----------+
            |                                     |
            v                                     v
+-----------------------+             +-----------------------+
|  Local ~/.ssh/*.pub   |             |  Remote OTP SSH Exec  |
+-----------------------+             +-----------------------+
```

### 2.1 SSHClient.SSH.KeyManager
Responsible for local SSH key discovery, inspection, and generation:
- `user_ssh_dir/0`: Resolves the OS user SSH directory (`~/.ssh` or `%USERPROFILE%\.ssh`).
- `list_public_keys/1`: Scans for existing public keys (`id_ed25519.pub`, `id_rsa.pub`, `id_ecdsa.pub`) and returns structured descriptors `%{type: atom(), path: Path.t(), content: String.t(), comment: String.t()}`.
- `get_default_public_key/1`: Picks the preferred public key (`ed25519` > `rsa` > `ecdsa`), or returns `{:error, :no_keys_found}`.
- `generate_ed25519_key_pair/1`: Uses OpenSSH `ssh-keygen` or OTP `:crypto` to generate a fresh `id_ed25519` key pair if no keys exist.

### 2.2 SSHClient.SSH.KeyDeployer
Handles the remote installation of the public key:
- `deploy_public_key/3`: Connects to the remote server using the authenticated session or credentials and executes an idempotent remote command:
  ```bash
  mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
  (grep -qxF '<PUBLIC_KEY>' ~/.ssh/authorized_keys 2>/dev/null || echo '<PUBLIC_KEY>' >> ~/.ssh/authorized_keys) && \
  chmod 600 ~/.ssh/authorized_keys
  ```
- Validates the exit code from `SSHClient.SSH.exec/3`.
- Calls `ServerManager.update_server/2` and `Config.save_file/2` to upgrade the target server configuration:
  - `default_auth_method: :key`
  - `auth_method: :key`
- Clears the ephemeral password from cache for that server.

### 2.3 Ephemeral Password Cache
- Utilizes `SSHClient.PassphraseCache` (ETS RAM-only table) to store session passwords under the key `password:<user>@<server_id>`.
- Removes the requirement for disk persistence or OS keychain CLI invocations.
- On connection close, session switch, or explicit user action, the password can be cleared from RAM.

### 2.4 UI Integration
- **Connect Modal (`HostLive`)**:
  - Displays password input when connecting to password-authenticated hosts.
  - Checkbox: "Deploy local SSH key after successful login" (checked by default when public keys exist).
- **Terminal View (`TerminalLive`)**:
  - When a terminal session successfully authenticates via password (and key has not been deployed yet), a subtle modal/banner is shown:
    - Title: "Deploy SSH Key for Passwordless Login?"
    - Content: "Installing your public key (`id_ed25519.pub`) on `user@host` enables secure, instant logins without passwords."
    - Actions: `[Deploy Key]` and `[Dismiss]`
  - Upon clicking `[Deploy Key]`, the key is installed asynchronously, showing a progress indicator and success confirmation.

---

## 3. Security Considerations

1. **Input Sanitization**:
   - The public key string is validated to match valid OpenSSH public key formats (`ssh-ed25519 <b64>`, `ssh-rsa <b64>`, etc.) and stripped of malicious shell injection characters before being interpolated into the remote command.
2. **File Permissions**:
   - Remote `~/.ssh` is strictly set to `0700` (`rwx------`).
   - Remote `~/.ssh/authorized_keys` is strictly set to `0600` (`rw-------`).
3. **Idempotence**:
   - `grep -qxF` prevents duplicate lines if the public key was previously added.

---

## 4. Verification Plan

1. **Unit Tests**:
   - `test/ssh_client/ssh/key_manager_test.exs`:
     - Test discovering public keys in custom directories.
     - Test handling when no public keys exist.
     - Test parsing public key types and comments.
   - `test/ssh_client/ssh/key_deployer_test.exs`:
     - Test command generation and public key sanitization.
     - Test successful execution and server config upgrade.
     - Test handling execution failures (e.g. read-only filesystem or permission denied).
2. **LiveView & Route Tests**:
   - `test/ssh_client_web/live/host_live_test.exs`:
     - Test password submission with ephemeral caching.
   - `test/ssh_client_web/live/terminal_live_test.exs`:
     - Test post-login key deployment prompt and dispatch.
3. **Full Suite & Release Sync Check**:
   - `mix test`
   - `python scripts/sync_release.py --check`
   - `python scripts/sync_release.py --emoji-check`
