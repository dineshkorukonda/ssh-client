# ssh-client

Lightweight, high-performance desktop SSH client with agentless remote host monitoring, multi-tab terminal, SFTP file management, and zero-disk ephemeral credential security.

Built on Elixir/OTP, Erlang `:ssh`, and Phoenix LiveView with xterm.js.

---

## Key Highlights

- **Zero-Cloud & Offline-First**: 100% self-contained. Configurations and keys never leave your machine.
- **Embedded Multi-Tab Terminal**: xterm.js with 24-bit TrueColor, bracketed paste, and auto-reconnect.
- **Agentless Host Telemetry**: Periodic CPU, RAM, disk, load metrics, and service checks over SSH.
- **Ephemeral Credentials & Auto Key Deploy**: Ephemeral in-memory password caching with one-click `ssh-copy-id` key deployment.
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

For pre-built installers (Windows `.exe` / `.zip`, Linux `.tar.gz`, container images) and complete guides, visit:

- **Website**: [ssh-client Documentation](https://dineshkorukonda.github.io/ssh-client/)
- **Releases**: [GitHub Releases](https://github.com/dineshkorukonda/ssh-client/releases)

---

## License

MIT License. See [LICENSE](LICENSE) for details.
