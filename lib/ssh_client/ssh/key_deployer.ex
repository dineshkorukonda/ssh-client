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
            "(grep -qxF " <>
            escape_shell_arg(clean_key) <>
            " ~/.ssh/authorized_keys 2>/dev/null || " <>
            "echo " <>
            escape_shell_arg(clean_key) <>
            " >> ~/.ssh/authorized_keys) && " <>
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

      # Persist to disk config and sync running manager
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

          try do
            ServerManager.sync_config(updated_servers)
          rescue
            _ -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp escape_shell_arg(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
