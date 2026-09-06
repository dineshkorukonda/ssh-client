# Multi-User Accounts & Password Authentication Design

## 1. Overview & Problem Statement
Previously, `ssh-client` only supported single-user host definitions (`user: String.t()`) and assumed SSH key authentication without an interactive or saved password flow in the UI. When a remote server has multiple authorized user accounts (e.g. `root`, `deploy`, `developer`), users were unable to switch or select which user to connect as. Furthermore, servers configured for password authentication failed or lacked an interface to supply or securely store credentials.

This design introduces:
1. **Multi-User Server Model**: Configurable list of accounts (`users: [String.t()]`) per server, with backward-compatible single `user` fallback.
2. **Password Authentication**: Support for `:password` authentication in Erlang/OTP `:ssh` connections.
3. **OS Keychain & Credential Store**: Seamless integration with `SSHClient.Keychain` (Windows Credential Manager / Linux libsecret) for saving and retrieving passwords per `user@server_id` account without ever saving plaintext passwords in `servers.yaml`.
4. **Connection-Time User & Auth Selection Modal**: In `HostLive`, connecting opens an editorial dark modal where the user can pick the target account, select Key vs Password auth, input/retrieve passwords, and toggle "Remember in Credential Manager".
5. **Session-Level Terminal & SFTP Integration**: `TerminalLive` and `SFTPLive` honor the selected user and authentication credentials.

---

## 2. Architecture & Data Flow

### 2.1 Server Configuration Schema (`SSHClient.Config.Server`)
Update `SSHClient.Config.Server`:
- Add field `users: list(String.t())` (defaults to `[user]` when only `user` is supplied).
- Add field `default_auth_method: :key | :password` (defaults to `:key`).
- In `from_map/1`:
  - Parse `users` from list or comma-separated string (e.g. `"root, ubuntu, deploy"`).
  - Ensure `user` represents the default user, and `users` contains at least `[user]`.
  - Validate that `users` is deduplicated and trimmed.

### 2.2 Credential Store (`SSHClient.Keychain`)
Account identification follows the format:
`"{user}@{server_id}"` (or `"{user}@{host}:{port}"`).
- `Keychain.store("#{user}@#{server_id}", password)`
- `Keychain.retrieve("#{user}@#{server_id}")`
- `Keychain.delete("#{user}@#{server_id}")`
Guarantees: Plaintext passwords are never written to `servers.yaml` on disk.

### 2.3 SSH Connection Pipeline (`SSHClient.SSH` & `SSHClient.SSH.Auth`)
- `SSH.connect/2` accepts target overrides:
  - `user`: chosen username for the session.
  - `password`: password charlist/string.
  - `auth_method`: `:password` or `:key`.
- `SSHClient.SSH.Auth.build_options/2` maps `:password` into:
  - `auth_methods: ~c"password,keyboard-interactive,publickey"` (or order specified).
  - `password: String.to_charlist(password)`
  - `keyboard_interact_fun`: configured with static or map password handler for OTP compatibility.

### 2.4 LiveView UI & Interaction (`HostLive`)
1. **Host List Cards / Table**:
   - Displays default user with indicator if multiple users exist (e.g. `root (+2)`).
   - "Connect" button opens the **Connect Modal** when the server has multiple users or uses password auth, or provides a direct dropdown for quick user launch.
2. **Connect Modal**:
   - Editorial dark theme (`#050505` bg, `#1f1f1f` borders, red/blue accents, zero emojis).
   - User selection pills (`[root]`, `[ubuntu]`) and custom user text input.
   - Authentication toggle (`SSH Key` / `Password`).
   - If `Password` is selected:
     - Password input (masked).
     - Indicator if a password is saved in OS Keychain.
     - "Remember password in OS Keychain" checkbox.
   - "Launch Terminal" and "Open SFTP" action buttons.

### 2.5 Terminal & SFTP Navigation
- Route parameters:
  - `/terminal/:id?user=ubuntu&auth=password`
  - `/sftp/:id?user=ubuntu`
- Terminal supervisor initializes session with specified `user` and resolved credentials from Keychain/params.
