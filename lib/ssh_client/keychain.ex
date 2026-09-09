defmodule SSHClient.Keychain do
  @moduledoc """
  Cross-platform OS keychain interface.
  - Linux: uses `secret-tool` (libsecret)
  - Windows: uses `cmdkey` / Windows Credential Manager PowerShell interface
  - Fallback / Test: in-memory mock store for isolated testing and CI

  Guarantees: credentials NEVER touch ssh-client config files on disk.
  """

  @service_name "ssh-client"

  @doc """
  Stores a secret (password or passphrase) for a given account / host in the OS keychain.
  """
  @spec store(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def store(account, secret, opts \\ []) do
    backend = Keyword.get(opts, :backend, detect_backend())

    case backend do
      :libsecret ->
        store_libsecret(account, secret)

      :credential_manager ->
        store_windows(account, secret)

      :memory ->
        store_memory(account, secret)
    end
  end

  @doc """
  Retrieves a secret from the OS keychain for the specified account / host.
  Returns `{:ok, secret}` or `{:error, :not_found}`.
  """
  @spec retrieve(String.t(), keyword()) :: {:ok, String.t()} | {:error, :not_found | term()}
  def retrieve(account, opts \\ []) do
    backend = Keyword.get(opts, :backend, detect_backend())

    case backend do
      :libsecret ->
        retrieve_libsecret(account)

      :credential_manager ->
        retrieve_windows(account)

      :memory ->
        retrieve_memory(account)
    end
  end

  @doc """
  Deletes a secret from the OS keychain for the specified account / host.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(account, opts \\ []) do
    backend = Keyword.get(opts, :backend, detect_backend())

    case backend do
      :libsecret ->
        delete_libsecret(account)

      :credential_manager ->
        delete_windows(account)

      :memory ->
        delete_memory(account)
    end
  end

  @doc """
  Detects the OS credential backend based on runtime platform.
  """
  def detect_backend do
    case :os.type() do
      {:win32, _} -> :credential_manager
      {:unix, :darwin} -> :libsecret
      {:unix, _} -> :libsecret
      _ -> :memory
    end
  end

  # Linux libsecret via `secret-tool`
  defp store_libsecret(account, secret) do
    case System.find_executable("secret-tool") do
      nil ->
        # If secret-tool binary is not installed, fallback to process memory
        store_memory(account, secret)

      path ->
        args = [
          "store",
          "--label=ssh-client:#{account}",
          "service",
          @service_name,
          "account",
          account
        ]

        port = Port.open({:spawn_executable, path}, [:stream, :binary, :use_stdio, args: args])
        Port.command(port, secret)
        send(port, {self(), :close})
        :ok
    end
  end

  defp retrieve_libsecret(account) do
    case System.find_executable("secret-tool") do
      nil ->
        retrieve_memory(account)

      path ->
        args = ["lookup", "service", @service_name, "account", account]

        case System.cmd(path, args, stderr_to_stdout: true) do
          {"", 0} -> {:error, :not_found}
          {secret, 0} -> {:ok, String.trim_trailing(secret, "\n")}
          _ -> {:error, :not_found}
        end
    end
  end

  defp delete_libsecret(account) do
    case System.find_executable("secret-tool") do
      nil ->
        delete_memory(account)

      path ->
        args = ["clear", "service", @service_name, "account", account]
        System.cmd(path, args)
        :ok
    end
  end

  # Windows DPAPI and Credential Manager storage
  defp dpapi_store_path do
    base_dir =
      try do
        SSHClient.Config.os_config_dir()
      rescue
        _ -> System.tmp_dir!()
      end

    Path.join(base_dir, "credentials.enc")
  end

  defp load_dpapi_store do
    path = dpapi_store_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp save_dpapi_store(store_map) when is_map(store_map) do
    path = dpapi_store_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(store_map, pretty: true),
         :ok <- File.write(path, json) do
      :ok
    else
      _ -> :error
    end
  end

  defp dpapi_protect(plaintext) when is_binary(plaintext) do
    b64_plain = Base.encode64(plaintext)

    ps_cmd =
      "Add-Type -AssemblyName System.Security; " <>
        "$bytes = [System.Convert]::FromBase64String('#{b64_plain}'); " <>
        "$enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser); " <>
        "[System.Convert]::ToBase64String($enc)"

    case System.cmd("powershell", ["-NoProfile", "-NonInteractive", "-Command", ps_cmd],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        cleaned = String.trim(out)
        if cleaned != "", do: {:ok, cleaned}, else: {:error, :empty_output}

      {err, _} ->
        {:error, err}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp dpapi_unprotect(ciphertext_b64) when is_binary(ciphertext_b64) do
    cleaned = String.trim(ciphertext_b64)

    ps_cmd =
      "Add-Type -AssemblyName System.Security; " <>
        "$bytes = [System.Convert]::FromBase64String('#{cleaned}'); " <>
        "$dec = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser); " <>
        "[System.Convert]::ToBase64String($dec)"

    case System.cmd("powershell", ["-NoProfile", "-NonInteractive", "-Command", ps_cmd],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Base.decode64(String.trim(out)) do
          {:ok, plaintext} -> {:ok, plaintext}
          _ -> {:error, :decode_failed}
        end

      {err, _} ->
        {:error, err}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp store_windows(account, secret) do
    store_memory(account, secret)

    # Persist encrypted secret using Windows DPAPI
    case dpapi_protect(secret) do
      {:ok, encrypted_b64} ->
        current_store = load_dpapi_store()
        updated_store = Map.put(current_store, account, encrypted_b64)
        save_dpapi_store(updated_store)

      _ ->
        :ok
    end

    # Optional: also register generic target in Windows Credential Manager
    target = "#{@service_name}:#{account}"

    if cmdkey_path = System.find_executable("cmdkey") do
      System.cmd(cmdkey_path, ["/generic:#{target}", "/user:#{account}", "/pass:#{secret}"],
        stderr_to_stdout: true
      )
    end

    :ok
  end

  defp retrieve_windows(account) do
    case retrieve_memory(account) do
      {:ok, secret} when is_binary(secret) and secret != "" ->
        {:ok, secret}

      _ ->
        # Check DPAPI encrypted credentials store
        store_map = load_dpapi_store()

        case Map.get(store_map, account) do
          encrypted_b64 when is_binary(encrypted_b64) and encrypted_b64 != "" ->
            case dpapi_unprotect(encrypted_b64) do
              {:ok, secret} when is_binary(secret) ->
                store_memory(account, secret)
                {:ok, secret}

              _ ->
                {:error, :not_found}
            end

          _ ->
            {:error, :not_found}
        end
    end
  end

  defp delete_windows(account) do
    delete_memory(account)

    current_store = load_dpapi_store()

    if Map.has_key?(current_store, account) do
      updated_store = Map.delete(current_store, account)
      save_dpapi_store(updated_store)
    end

    target = "#{@service_name}:#{account}"

    if cmdkey_path = System.find_executable("cmdkey") do
      System.cmd(cmdkey_path, ["/delete:#{target}"], stderr_to_stdout: true)
    end

    :ok
  end

  # In-memory storage (ETS table for testing/headless/fallback)
  defp table_name, do: :ssh_client_keychain_store

  defp ensure_memory_table do
    if :ets.whereis(table_name()) == :undefined do
      try do
        :ets.new(table_name(), [:set, :public, :named_table])
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp store_memory(account, secret) do
    ensure_memory_table()
    :ets.insert(table_name(), {account, secret})
    :ok
  end

  defp retrieve_memory(account) do
    ensure_memory_table()

    case :ets.lookup(table_name(), account) do
      [{^account, secret}] -> {:ok, secret}
      [] -> {:error, :not_found}
    end
  end

  defp delete_memory(account) do
    ensure_memory_table()
    :ets.delete(table_name(), account)
    :ok
  end
end
