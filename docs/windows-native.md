# Native Windows application

Windows launches a self-contained WPF application, `ssh-client.exe`. The terminal uses locally bundled xterm.js in WebView2; the rest of the UI uses native controls. Linux and container distributions use the browser interface and share the OTP backend.

## Daily workflows

- Start on Hosts, add a host or import an OpenSSH config. Search names, endpoints and tags; sort by name, recent connection or favorites.
- Choose private-key, password or keyboard-interactive authentication. Registered private identities are selectable in the editor. Destination and bastion credentials remain separate.
- Ctrl+K opens hosts and app commands. Quick connect accepts `user@host:port` and `ssh://user@[IPv6]:port`; invalid ports are rejected.
- Terminal tabs own their pane sessions. Disconnect/reconnect applies to the tab's panes; Split right starts another authenticated session. Each pane shows its backend state. Closing a tab closes its backend sessions and terminal pollers.
- Files opens the selected connected session's local/remote browser. Uploads and downloads run in the background queue with progress, cancel and retry. Drag and picker uploads share replacement confirmation. Folder uploads and folder deletion are currently unsupported and do not show success.
- Settings saves terminal font size, scrollback, theme and reduced motion, and applies preferences to open terminals.
- Named workspaces save host references and pane counts. Restore asks before reconnecting and prompts for credentials. Databases can be backed up; host metadata can be exported/imported without overwriting existing host identities.

## Local security and identities

There is no Windows app account or master-vault login. Passwords and passphrases are supplied per connection and stay in memory. Lock Windows delegates desktop protection to Windows; SSH sessions continue. Closing the app ends the owned backend and its sessions.

Key import inspects actual public/private keys and computes an OpenSSH SHA256 fingerprint. Generation produces Ed25519 or RSA-4096 key files using OTP. Generated private keys are explicitly unencrypted: choose a private destination and protect it with Windows file permissions. Existing key files are never replaced. Removing a registered identity removes its app metadata, not its files. SQLite stores public keys and identity paths, not private-key contents or connection passwords. Backups exclude private-key files.

Encrypted-key compatibility depends on OTP's decoder. Unsupported formats fail with a connection/import error; an identity is never silently replaced. First-use and changed server keys require fingerprint approval. Keyboard-interactive prompts belong to their connection attempt; cancellation ends that attempt.

The desktop API requires a fresh per-process bearer token and rejects browser origins and non-loopback callers. Native mode forces loopback binding even if the environment requests a public interface. Terminal JavaScript receives neither tokens nor connection credentials.

## Startup, recovery and diagnostics

Startup shows an explicit Starting state. Failure offers Retry. A stopped backend leaves the window available with a recovery action; restarting ends old sessions, and a saved workspace can reconnect them. Form values remain visible when an operation fails. Diagnostics show actual backend version/readiness; logs are under `%LOCALAPPDATA%/ssh-client/logs`. Review copied diagnostics before sharing them.

## Build and verification

Install Elixir/OTP, Python and .NET 10, then run:

```powershell
mix deps.get
python scripts/check.py
dotnet run --project windows/tests/HostContract -c Release
./scripts/build_windows.ps1
./scripts/test_native_windows.ps1
```

The package includes its OTP runtime and Microsoft's signed offline WebView2 installer. Distributed builds must not use `-SkipRuntimeDownload`. The installer uses the app's per-user shutdown signal and Windows Restart Manager; unrelated Erlang processes are not terminated.

Automated validation exercises the actual MainWindow host editor, preferences, command results, session selection/lifetime and integrated file browser, plus the native connection form for password login and cancellation. It also checks real terminal/SFTP behavior, process cleanup, resource-key uniqueness, minimum-width rendering and scaled bitmap rendering. Scaled renders do not replace interactive Windows DPI testing.

Before release, also test Narrator and keyboard-only navigation, Windows display/text scaling, high contrast, sleep/resume, first-use/changed-key rejection, keyboard-interactive authentication, distinct bastion credentials, unsupported encrypted keys, offline WebView2 installation, upgrade/uninstall and signing on clean machines. CI must pass before merging; retain branch context until post-merge release workflows finish.

## Release outputs

The release pipeline validates Windows and Linux, builds the Windows installer/portable ZIP and Linux x64 tarball, and validates a non-root container for linux/amd64 and linux/arm64. Only version tags publish downloads and `ghcr.io/dineshkorukonda/ssh-client:<version>` / `:latest`. Branch runs do not publish releases. Version metadata is advanced by the Release Bot after each merge, and GitHub releases are marked latest.
