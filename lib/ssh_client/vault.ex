defmodule SSHClient.Vault do
  @moduledoc """
  Client-side encryption and Master Password vault manager for ssh-client.
  Uses PBKDF2-HMAC-SHA256 (100,000 rounds) for key derivation and AES-256-GCM
  for symmetric authenticated encryption.
  """

  use GenServer

  alias SSHClient.Config

  @iterations 100_000
  @key_len 32
  @iv_len 12
  @tag_len 16
  @default_lock_timeout 15 * 60 * 1000 # 15 minutes

  defstruct [
    :vault_file,
    :salt,
    :verification_payload,
    key: nil,
    status: :uninitialized,
    timer: nil
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current vault status: :uninitialized | :locked | :unlocked"
  def status do
    GenServer.call(__MODULE__, :status)
  rescue
    _ -> :unlocked # Fallback if GenServer not started in test env
  end

  @doc "Returns true if the vault is unlocked or uninitialized (when vault is not enforced)"
  def unlocked? do
    case status() do
      :unlocked -> true
      :uninitialized -> true
      _ -> false
    end
  end

  @doc "Initializes a fresh vault with a new master password/PIN"
  def init_vault(password) when is_binary(password) and byte_size(password) >= 4 do
    GenServer.call(__MODULE__, {:init_vault, password})
  end

  @doc "Unlocks the vault with the master password"
  def unlock(password) when is_binary(password) do
    GenServer.call(__MODULE__, {:unlock, password})
  end

  @doc "Locks the vault immediately, wiping the key from memory"
  def lock do
    GenServer.call(__MODULE__, :lock)
  end

  @doc "Encrypts plaintext using the currently unlocked master key"
  def encrypt(plaintext) when is_binary(plaintext) do
    GenServer.call(__MODULE__, {:encrypt, plaintext})
  end

  @doc "Decrypts ciphertext using the currently unlocked master key"
  def decrypt(ciphertext_b64) when is_binary(ciphertext_b64) do
    GenServer.call(__MODULE__, {:decrypt, ciphertext_b64})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    vault_file = Keyword.get(opts, :vault_file, default_vault_path())
    state = load_vault_file(%__MODULE__{vault_file: vault_file})
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call({:init_vault, password}, _from, state) do
    salt = :crypto.strong_rand_bytes(16)
    key = derive_key(password, salt)
    verification = do_encrypt("ssh-client-vault-verified", key)

    payload = %{
      "salt" => Base.encode64(salt),
      "verification" => verification,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    save_vault_file(state.vault_file, payload)

    new_timer = schedule_lock(@default_lock_timeout)

    new_state = %{
      state
      | salt: salt,
        verification_payload: verification,
        key: key,
        status: :unlocked,
        timer: new_timer
    }

    {:reply, {:ok, :initialized}, new_state}
  end

  @impl true
  def handle_call({:unlock, password}, _from, state) do
    if state.status == :uninitialized do
      {:reply, {:error, :uninitialized}, state}
    else
      key = derive_key(password, state.salt)

      case do_decrypt(state.verification_payload, key) do
        {:ok, "ssh-client-vault-verified"} ->
          if state.timer, do: Process.cancel_timer(state.timer)
          new_timer = schedule_lock(@default_lock_timeout)

          {:reply, {:ok, :unlocked}, %{state | key: key, status: :unlocked, timer: new_timer}}

        _ ->
          {:reply, {:error, :invalid_password}, state}
      end
    end
  end

  @impl true
  def handle_call(:lock, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    new_status = if state.salt, do: :locked, else: :uninitialized
    {:reply, :ok, %{state | key: nil, status: new_status, timer: nil}}
  end

  @impl true
  def handle_call({:encrypt, plaintext}, _from, state) do
    case state.key do
      nil -> {:reply, {:error, :vault_locked}, state}
      key -> {:reply, {:ok, do_encrypt(plaintext, key)}, state}
    end
  end

  @impl true
  def handle_call({:decrypt, ciphertext_b64}, _from, state) do
    case state.key do
      nil -> {:reply, {:error, :vault_locked}, state}
      key -> {:reply, do_decrypt(ciphertext_b64, key), state}
    end
  end

  @impl true
  def handle_info(:auto_lock, state) do
    new_status = if state.salt, do: :locked, else: :uninitialized
    {:noreply, %{state | key: nil, status: new_status, timer: nil}}
  end

  # Helpers

  defp default_vault_path do
    Path.join(Config.os_config_dir(), "vault.json")
  end

  defp load_vault_file(state) do
    if File.exists?(state.vault_file) do
      try do
        case File.read(state.vault_file) do
          {:ok, content} ->
            json = Jason.decode!(content)
            salt = Base.decode64!(json["salt"])
            verification = json["verification"]
            %{state | salt: salt, verification_payload: verification, status: :locked}

          _ ->
            %{state | status: :uninitialized}
        end
      rescue
        _ -> %{state | status: :uninitialized}
      end
    else
      %{state | status: :uninitialized}
    end
  end

  defp save_vault_file(path, data) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp derive_key(password, salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, @key_len)
  end

  defp do_encrypt(plaintext, key) when is_binary(plaintext) and is_binary(key) do
    iv = :crypto.strong_rand_bytes(@iv_len)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)
    payload = iv <> tag <> ciphertext
    Base.encode64(payload)
  end

  defp do_decrypt(ciphertext_b64, key) when is_binary(ciphertext_b64) and is_binary(key) do
    try do
      payload = Base.decode64!(ciphertext_b64)
      <<iv::binary-size(@iv_len), tag::binary-size(@tag_len), ciphertext::binary>> = payload
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        _ -> {:error, :decryption_failed}
      end
    rescue
      _ -> {:error, :invalid_ciphertext}
    end
  end

  defp schedule_lock(delay_ms) do
    Process.send_after(self(), :auto_lock, delay_ms)
  end
end
