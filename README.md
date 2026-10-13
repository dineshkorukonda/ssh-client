# ssh-client

Lightweight, high-performance desktop SSH client with agentless remote host monitoring, multi-tab terminal, SFTP file management, and zero-disk ephemeral credential security.

Built on Elixir/OTP, Erlang `:ssh`, and Phoenix LiveView with xterm.js.

---

## Key Highlights

- **Zero-Cloud & Offline-First**: 100% self-contained. Configurations and keys never leave your machine.
- **Embedded Multi-Tab Terminal**: xterm.js with 24-bit TrueColor, bracketed paste, split panes, and auto-reconnect. Sessions survive LiveView reconnect.
- **SFTP Transfer Queue**: Background uploads/downloads with progress, cancel, retry, rename, and hidden-file toggle. Transfers can use an independent SSH connection.
- **Workspaces and Port Forwards**: Named host groups plus local/remote TCP forwarding.
- **Local credentials and identities**: Windows connection passwords/passphrases stay in memory. Private keys remain in user-selected files; generated private keys are unencrypted. The browser interface retains its local vault workflow.
- **Agentless Host Telemetry**: Periodic CPU, RAM, disk, load metrics, and service checks over SSH.
- **Pure OTP Transport**: Native Erlang `:ssh` engine without external OpenSSH binary dependencies.

---

## Quick Start

### Development

```bash
# Clone and install dependencies
git clone https://github.com/dineshkorukonda/ssh-client.git
cd ssh-client

mix deps.get
iex -S mix
```

### Running Tests

```bash
mix test
```

---

## Documentation & Downloads

On Windows, use **Settings > Check for updates > Install and restart** to upgrade
in place. Installed copies use the Windows installer; portable copies use the ZIP
package. The app closes active sessions during restart and preserves saved hosts,
preferences and local SSH key files. An older version without these controls can
be upgraded by running the new installer over the existing installation, without
uninstalling first.

New hosts can use private keys discovered in your local `.ssh` folder or referenced
by explicit `IdentityFile` entries. You can also choose another file directly in
the host form. Bcrypt-encrypted OpenSSH keys are identified but cannot be decrypted
by the bundled SSH engine; encrypted PEM keys remain supported.

For pre-built installers (Windows `.exe` / `.zip`, Linux `.tar.gz`, container images) and complete guides, visit:

- **Website**: [ssh-client Documentation](https://dineshkorukonda.github.io/ssh-client/)
- **Releases**: [GitHub Releases](https://github.com/dineshkorukonda/ssh-client/releases)

---

## License

MIT License. See [LICENSE](LICENSE) for details.
