# Ephemeral Passwords & Auto SSH Key Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide zero-disk ephemeral password authentication and automated one-click SSH key provisioning (`ssh-copy-id`) to remote servers.

**Architecture:** A local `KeyManager` discovers and parses existing public keys (`id_ed25519.pub`, `id_rsa.pub`, `id_ecdsa.pub`), while `KeyDeployer` connects via SSH using ephemeral credentials and executes an idempotent remote installation script before upgrading the server's configuration to `:key` authentication. `HostLive` and `TerminalLive` present the interactive deployment modal upon connecting.

**Tech Stack:** Elixir 1.18, Erlang/OTP `:ssh` and `:crypto`, Phoenix LiveView, Tailwind CSS.

**Spec:** `docs/superpowers/specs/2026-09-07-auto-deploy-ssh-key-and-ephemeral-passwords-design.md`

## Global Constraints
- Zero disk password persistence (passwords only in memory cache, never written to `servers.json` or OS cmdkey).
- No emojis anywhere in code, comments, templates, commit messages, or tests (per AGENTS.md rule 3).
- Remote installation must be idempotent (`grep -qxF`) with strict POSIX permissions (`0700` ~/.ssh, `0600` authorized_keys).
- Sanitized public key content against shell injection characters.

---

### Task 1: SSHClient.SSH.KeyManager for Local Key Discovery & Parsing

**Files:**
- Create: `lib/ssh_client/ssh/key_manager.ex`
- Create: `test/ssh_client/ssh/key_manager_test.exs`

**Interfaces:**
- Produces:
  - `SSHClient.SSH.KeyManager.user_ssh_dir() :: Path.t()`
  - `SSHClient.SSH.KeyManager.list_public_keys(opts \\ []) :: {:ok, list(map())}`
  - `SSHClient.SSH.KeyManager.get_default_public_key(opts \\ []) :: {:ok, map()} | {:error, :no_keys_found}`
  - `SSHClient.SSH.KeyManager.sanitize_public_key(content :: String.t()) :: {:ok, String.t()} | {:error, :invalid_public_key}`

- [ ] **Step 1: Write the failing tests in `test/ssh_client/ssh/key_manager_test.exs`**

```elixir
defmodule SSHClient.SSH.KeyManagerTest do
  use ExUnit.Case, async: true

  alias SSHClient.SSH.KeyManager

  @temp_dir Path.join(System.tmp_dir!(), "ssh_client_km_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@temp_dir)
    on_exit(fn -> File.rm_rf(@temp_dir) end)
    %{ssh_dir: @temp_dir}
  end

  test "returns :no_keys_found when ssh directory is empty", %{ssh_dir: ssh_dir} do
    assert KeyManager.get_default_public_key(ssh_dir: ssh_dir) == {:error, :no_keys_found}
    assert {:ok, []} = KeyManager.list_public_keys(ssh_dir: ssh_dir)
  end

  test "discovers and prioritizes ed25519 over rsa and ecdsa", %{ssh_dir: ssh_dir} do
    rsa_path = Path.join(ssh_dir, "id_rsa.pub")
    ed_path = Path.join(ssh_dir, "id_ed25519.pub")

    File.write!(rsa_path, "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC user@host\n")
    File.write!(ed_path, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI user@host\n")

    {:ok, keys} = KeyManager.list_public_keys(ssh_dir: ssh_dir)
    assert length(keys) == 2

    {:ok, default_key} = KeyManager.get_default_public_key(ssh_dir: ssh_dir)
    assert default_key.type == :ed25519
    assert default_key.path == ed_path
    assert String.starts_with?(default_key.content, "ssh-ed25519")
  end

  test "sanitizes valid public key strings and rejects shell injection attempts" do
    valid_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGf test@box"
    assert {:ok, sanitized} = KeyManager.sanitize_public_key(valid_key)
    assert sanitized == valid_key

    injection_attempt = "ssh-ed25519 AAAAC3NzaC1; rm -rf /; test@box"
    assert {:error, :invalid_public_key} = KeyManager.sanitize_public_key(injection_attempt)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ssh_client/ssh/key_manager_test.exs`
Expected: FAIL with undefined module `SSHClient.SSH.KeyManager`

- [ ] **Step 3: Implement `SSHClient.SSH.KeyManager` in `lib/ssh_client/ssh/key_manager.ex`**

```elixir
defmodule SSHClient.SSH.KeyManager do
  @moduledoc """
  Discovers, inspects, and sanitizes local OpenSSH public keys.
  """

  @standard_public_keys [
    {"id_ed25519.pub", :ed25519},
    {"id_rsa.pub", :rsa},
    {"id_ecdsa.pub", :ecdsa}
  ]

  @doc """
  Resolves the local user's .ssh directory path.
  """
  @spec user_ssh_dir() :: Path.t()
  def user_ssh_dir do
    Path.expand("~/.ssh")
  end

  @doc """
  Lists all available public keys found in the ssh directory.
  """
  @spec list_public_keys(keyword()) :: {:ok, list(map())}
  def list_public_keys(opts \\ []) do
    dir = Keyword.get(opts, :ssh_dir, user_ssh_dir())

    if File.dir?(dir) do
      keys =
        @standard_public_keys
        |> Enum.flat_map(fn {filename, type} ->
          path = Path.join(dir, filename)

          if File.exists?(path) do
            case File.read(path) do
              {:ok, content} ->
                trimmed = String.trim(content)

                case sanitize_public_key(trimmed) do
                  {:ok, clean} ->
                    comment = extract_comment(clean)
                    [%{type: type, filename: filename, path: path, content: clean, comment: comment}]

                  _ ->
                    []
                end

              _ ->
                []
            end
          else
            []
          end
        end)

      {:ok, keys}
    else
      {:ok, []}
    end
  end

  @doc """
  Returns the preferred default public key.
  """
  @spec get_default_public_key(keyword()) :: {:ok, map()} | {:error, :no_keys_found}
  def get_default_public_key(opts \\ []) do
    case list_public_keys(opts) do
      {:ok, [primary | _]} -> {:ok, primary}
      _ -> {:error, :no_keys_found}
    end
  end

  @doc """
  Validates that a public key string conforms to OpenSSH standard format and contains no shell injection chars.
  """
  @spec sanitize_public_key(String.t()) :: {:ok, String.t()} | {:error, :invalid_public_key}
  def sanitize_public_key(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    # Valid OpenSSH key format: (key-type) (base64) (optional comment)
    regex = ~r/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\s+([A-Za-z0-9+\/=]+)(\s+[^\r\n;`$|&><]*)?$/

    if Regex.match?(regex, trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_public_key}
    end
  end

  def sanitize_public_key(_), do: {:error, :invalid_public_key}

  defp extract_comment(content) do
    case String.split(content, ~r/\s+/, parts: 3) do
      [_, _, comment] -> String.trim(comment)
      _ -> ""
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/ssh_client/ssh/key_manager_test.exs`
Expected: 3 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/ssh_client/ssh/key_manager.ex test/ssh_client/ssh/key_manager_test.exs
git commit -m "feat(ssh): implement KeyManager for local public key discovery and sanitization"
```

---

### Task 2: SSHClient.SSH.KeyDeployer for Remote Public Key Installation

**Files:**
- Create: `lib/ssh_client/ssh/key_deployer.ex`
- Create: `test/ssh_client/ssh/key_deployer_test.exs`

**Interfaces:**
- Consumes:
  - `SSHClient.SSH.KeyManager.sanitize_public_key/1`
  - `SSHClient.SSH.connect/2`
  - `SSHClient.SSH.exec/3`
  - `SSHClient.ServerManager.update_server/2`
- Produces:
  - `SSHClient.SSH.KeyDeployer.build_install_script(public_key :: String.t()) :: {:ok, String.t()} | {:error, term()}`
  - `SSHClient.SSH.KeyDeployer.deploy(server_or_host, public_key_content, opts \\ []) :: {:ok, :deployed} | {:error, term()}`

- [ ] **Step 1: Write the failing tests in `test/ssh_client/ssh/key_deployer_test.exs`**

```elixir
defmodule SSHClient.SSH.KeyDeployerTest do
  use ExUnit.Case, async: true

  alias SSHClient.SSH.KeyDeployer

  test "builds idempotent POSIX install script with proper directory and file permissions" do
    pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGf user@box"
    {:ok, script} = KeyDeployer.build_install_script(pub_key)

    assert String.contains?(script, "mkdir -p ~/.ssh")
    assert String.contains?(script, "chmod 700 ~/.ssh")
    assert String.contains?(script, "grep -qxF 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGf user@box'")
    assert String.contains?(script, "chmod 600 ~/.ssh/authorized_keys")
  end

  test "rejects invalid public key when building install script" do
    assert {:error, :invalid_public_key} = KeyDeployer.build_install_script("malicious; rm -rf /")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ssh_client/ssh/key_deployer_test.exs`
Expected: FAIL with undefined module `SSHClient.SSH.KeyDeployer`

- [ ] **Step 3: Implement `SSHClient.SSH.KeyDeployer` in `lib/ssh_client/ssh/key_deployer.ex`**

```elixir
defmodule SSHClient.SSH.KeyDeployer do
  @moduledoc """
  Deploys local public SSH keys to remote hosts (ssh-copy-id equivalent) and upgrades
  the server configuration to public key authentication.
  """

  alias SSHClient.Config
  alias SSHClient.PassphraseCache
  alias SSHClient.ServerManager
  alias SSHClient.SSH
  alias SSHClient.SSH.KeyManager

  @doc """
  Builds the idempotent shell script that provisions the public key.
  """
  @spec build_install_script(String.t()) :: {:ok, String.t()} | {:error, term()}
  def build_install_script(public_key) do
    case KeyManager.sanitize_public_key(public_key) do
      {:ok, clean_key} ->
        script =
          "sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && " <>
            "(grep -qxF " <> escape_shell_arg(clean_key) <> " ~/.ssh/authorized_keys 2>/dev/null || " <>
            "echo " <> escape_shell_arg(clean_key) <> " >> ~/.ssh/authorized_keys) && " <>
            "chmod 600 ~/.ssh/authorized_keys'"

        {:ok, script}

      error ->
        error
    end
  end

  @doc """
  Deploys the specified public key to a remote server.
  On success, automatically updates the server configuration to `:key` authentication.
  """
  @spec deploy(map() | struct(), String.t(), keyword()) :: {:ok, :deployed} | {:error, term()}
  def deploy(server, public_key, opts \\ []) do
    with {:ok, script} <- build_install_script(public_key),
         {:ok, conn} <- SSH.connect(server, opts) do
      try do
        case SSH.exec(conn, script, timeout: Keyword.get(opts, :timeout, 15_000)) do
          {:ok, _stdout, 0} ->
            upgrade_server_to_key_auth(server)
            {:ok, :deployed}

          {:ok, stderr_or_out, exit_code} ->
            {:error, {:remote_execution_failed, exit_code, stderr_or_out}}

          {:error, reason} ->
            {:error, {:exec_error, reason}}
        end
      after
        SSH.close(conn)
      end
    end
  end

  defp upgrade_server_to_key_auth(server) do
    server_id = Map.get(server, :id) || Map.get(server, "id")

    if server_id do
      user = Map.get(server, :user) || Map.get(server, "user") || "root"
      PassphraseCache.delete("password:#{user}@#{server_id}")

      # Update ServerManager in-memory registry
      ServerManager.update_server(server_id, %{
        auth_method: :key,
        default_auth_method: :key
      })

      # Persist to disk config
      case Config.load_config() do
        {:ok, %Config{servers: servers} = cfg} ->
          updated_servers =
            Enum.map(servers, fn s ->
              if s.id == server_id do
                %{s | auth_method: :key, default_auth_method: :key}
              else
                s
              end
            end)

          Config.save_file(%{cfg | servers: updated_servers}, Config.default_config_path())

        _ ->
          :ok
      end
    end
  end

  defp escape_shell_arg(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/ssh_client/ssh/key_deployer_test.exs`
Expected: 2 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/ssh_client/ssh/key_deployer.ex test/ssh_client/ssh/key_deployer_test.exs
git commit -m "feat(ssh): implement KeyDeployer for remote authorized_keys provisioning"
```

---

### Task 3: Ephemeral Password Cache Integration in SSH Connection Engine

**Files:**
- Modify: `lib/ssh_client/ssh.ex`
- Modify: `lib/ssh_client/ssh/auth.ex`
- Test: `test/ssh_client/ssh/auth_test.exs`

**Interfaces:**
- Consumes: `SSHClient.PassphraseCache.get/1`, `SSHClient.PassphraseCache.put/2`
- Produces: Seamless retrieval of ephemeral session password under `password:<user>@<server_id>` without disk/keychain fallback requirement.

- [ ] **Step 1: Write the test in `test/ssh_client/ssh/auth_test.exs`**

```elixir
test "resolves password from PassphraseCache if provided in memory" do
  SSHClient.PassphraseCache.put("password:admin@test-host", "ephemeral-secret-123")
  target = %{id: "test-host", user: "admin", auth_method: :password}
  opts = SSHClient.SSH.Auth.build_options(target, user: "admin")
  assert Keyword.get(opts, :password) == ~c"ephemeral-secret-123"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ssh_client/ssh/auth_test.exs`
Expected: FAIL

- [ ] **Step 3: Modify `lib/ssh_client/ssh/auth.ex` and `lib/ssh_client/ssh.ex` to check `PassphraseCache`**

In `lib/ssh_client/ssh/auth.ex`, resolve password checking `opts[:password]`, then `PassphraseCache.get("password:#{user}@#{server_id}")`, then `PassphraseCache.get(account)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/ssh_client/ssh/auth_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ssh_client/ssh.ex lib/ssh_client/ssh/auth.ex test/ssh_client/ssh/auth_test.exs
git commit -m "feat(ssh): resolve ephemeral passwords from PassphraseCache"
```

---

### Task 4: Interactive Auto-Deploy SSH Key Modal in HostLive and TerminalLive

**Files:**
- Modify: `lib/ssh_client_web/live/host_live.ex`
- Modify: `lib/ssh_client_web/live/terminal_live.ex`
- Test: `test/ssh_client_web/live/host_live_test.exs`
- Test: `test/ssh_client_web/live/terminal_live_test.exs`

- [ ] **Step 1: Write failing tests in `test/ssh_client_web/live/terminal_live_test.exs`**

Add tests verifying that:
1. When connecting with `auth=password`, `terminal_live` mounts with the deploy key prompt enabled if a local public key is available.
2. Clicking `deploy_key` calls `KeyDeployer.deploy/3` and displays success notification.
3. Clicking `dismiss_deploy_key` closes the prompt modal.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ssh_client_web/live/terminal_live_test.exs`
Expected: FAIL

- [ ] **Step 3: Implement the prompt modal and events in `TerminalLive` and `HostLive`**

- In `HostLive`:
  - When submitting connect modal with password, cache password in `PassphraseCache.put("password:#{user}@#{server.id}", password)` (volatile RAM only).
- In `TerminalLive`:
  - Handle `deploy_ssh_key` event: calls `KeyDeployer.deploy(server, key.content, user: user, password: password)` asynchronously.
  - Render an editorial, dark-themed modal:
    - "Deploy SSH Key for Passwordless Login?"
    - Shows the key path (`~/.ssh/id_ed25519.pub`) and remote target (`user@host`).
    - Buttons: `[Deploy Key (Recommended)]` and `[Dismiss]`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ssh_client_web/live/host_live_test.exs test/ssh_client_web/live/terminal_live_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ssh_client_web/live/host_live.ex lib/ssh_client_web/live/terminal_live.ex test/ssh_client_web/live/host_live_test.exs test/ssh_client_web/live/terminal_live_test.exs
git commit -m "feat(ui): add auto deploy SSH key modal and ephemeral password handling in LiveViews"
```

---

### Task 5: Full Test Suite, Release & Emoji Verification

**Files:**
- Run scripts and test suite.

- [ ] **Step 1: Run full test suite**

Run: `mix test`
Expected: All tests pass.

- [ ] **Step 2: Run release and emoji sync checks**

Run:
- `python scripts/sync_release.py --check`
- `python scripts/sync_release.py --emoji-check`
- `python scripts/test_sync_release.py`
Expected: All pass with 0 errors.

- [ ] **Step 3: Commit any final test adjustments**

```bash
git commit -m "chore: verify full test suite and emoji compliance for auto key deploy"
```
