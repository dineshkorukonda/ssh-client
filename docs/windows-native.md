# Native Windows application

Windows now launches `ssh-client.exe`, a self-contained .NET WPF application. Hosts, connection and trust dialogs, settings, named workspaces, tabs and the remote file browser use native controls. The terminal uses locally bundled xterm.js inside WebView2. Edge/Chrome app mode is no longer the installed entry point.

## Build and verification

Install Elixir/OTP, Python and the .NET 10 SDK for development, then run:

```powershell
mix deps.get
python scripts/check.py
./scripts/build_windows.ps1
mix test test/integration/local_ssh_integration_test.exs --include integration
./scripts/test_native_windows.ps1
```

The build produces `_build/prod/rel/ssh_client/ssh-client.exe` with the OTP runtime, terminal assets and Microsoft's signed Evergreen WebView2 standalone installer. This offline installer is bundled in both Windows distributions. The app uses an existing WebView2 runtime or installs the bundled runtime per user when needed. No development SDK, external browser or network download is required on the destination machine. `-SkipRuntimeDownload` is for developer validation with an already installed WebView2 runtime; do not use it for distributed packages.

GitHub CI validates the native executable, real SSH terminal rendering, input/output, SFTP and owned-process cleanup, then compiles the Inno Setup installer and portable ZIP on every PR. Releases currently target Windows x64 only and wait for Windows validation and both Windows artifacts. The Release Bot advances synchronized beta versions after merge; the native executable's version is derived from the same release metadata.

## Data and session lifecycle

Hosts, named workspaces and preferences live in `app.sqlite3` in the per-user configuration directory. Existing host JSON and `app-store.json` are imported once, preserving identities, jump hosts, favorites, tags and monitoring checks. The original files remain untouched; deleting an imported host does not bring it back on the next launch. SQLite edits take precedence over imported records. Terminal layout data remains in its separate SQLite workspace database.

The Windows app does not start the credential vault or read passwords from the keychain. Passwords and passphrases are entered for each session and remain in memory. SQLite stores identity file paths, not private-key contents or login secrets. Terminal tabs restore from their saved host IDs after an explicit restore action.

The Back up data button takes SQLite `VACUUM INTO` snapshots of both databases, including committed WAL data. Credential files are excluded from backups. Closing the Windows app ends its remote sessions. Switching native terminal tabs keeps those sessions alive.

The launcher owns its backend through a Windows Job Object. Closing or crashing the app terminates only that backend process tree. `ssh-client.exe --shutdown` signals the running app for the current user; installer updates and uninstall use this signal and Windows Restart Manager instead of killing all Erlang processes. Logs live under `%LOCALAPPDATA%\ssh-client\logs`.

## Authentication and compatibility

Selected identities use the exact file, including nonstandard filenames. Unencrypted OpenSSH keys and supported encrypted PEM keys use the OTP transport. Passphrases remain in memory for the session. Encrypted OpenSSH formats using bcrypt depend on OTP decoder support and are not covered by the PEM regression test; unsupported formats must be reported as a connection failure, never silently replaced with another identity.

First-use and changed host keys require explicit fingerprint approval. Trust is bound to hostname and port, including the original destination behind a bastion. Bastion credentials can be entered separately. Keyboard-interactive prompts are native dialogs, bound to their connection attempt; cancelling the dialog cancels that session.

The loopback desktop API is disabled outside native launch mode. Each backend receives a fresh random authentication token; native requests must present it and browser-origin requests are rejected. Tokens and credentials are never placed in terminal JavaScript or URLs.

## Clean-machine release checklist

- Install and run on supported Windows x64 without Elixir or .NET SDKs and with no WebView2 runtime installed; verify offline runtime installation.
- Extract the portable ZIP into a path containing spaces and launch `ssh-client.exe`.
- Verify password, key and keyboard-interactive login; first-use approval and changed-key rejection; separate bastion credentials; PTY resize; SFTP upload/download.
- Verify reconnect after network loss and sleep/resume, multiple tabs, settings and saved workspace restoration.
- Upgrade over the preceding beta and uninstall while running; verify the app closes and unrelated Erlang applications remain alive.
- Verify both Windows artifacts and the latest GitHub Release before deleting phase branches.

Automated smoke tests cover packaged backend startup, the WebView2 terminal bridge, real SSH/SFTP and backend cleanup. Offline runtime installation on a clean machine, sleep/resume, installer upgrade/uninstall and application signing require release-environment validation; do not treat compilation alone as proof of those behaviors.
