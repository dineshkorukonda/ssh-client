defmodule SSHClient.VaultTest do
  use ExUnit.Case, async: false
  alias SSHClient.Vault

  @test_vault_path "test/tmp/test_vault.json"

  setup do
    File.rm_rf!("test/tmp")
    File.mkdir_p!("test/tmp")

    if Process.whereis(Vault) do
      # Start with clean state
      GenServer.stop(Vault, :normal)
    end

    {:ok, pid} = Vault.start_link(vault_file: @test_vault_path)

    on_exit(fn ->
      File.rm_rf!("test/tmp")
    end)

    {:ok, vault_pid: pid}
  end

  test "vault lifecycle: uninitialized -> init -> lock -> unlock -> encrypt/decrypt" do
    assert Vault.status() == :uninitialized

    # Initialize vault
    assert {:ok, :initialized} = Vault.init_vault("secret123")
    assert Vault.status() == :unlocked

    # Encrypt data
    assert {:ok, ciphertext} = Vault.encrypt("my-ssh-private-key-data")
    assert is_binary(ciphertext)
    assert ciphertext != "my-ssh-private-key-data"

    # Decrypt data
    assert {:ok, "my-ssh-private-key-data"} = Vault.decrypt(ciphertext)

    # Lock vault
    assert :ok = Vault.lock()
    assert Vault.status() == :locked
    assert {:error, :vault_locked} = Vault.encrypt("test")
    assert {:error, :vault_locked} = Vault.decrypt(ciphertext)

    # Unlock with wrong password
    assert {:error, :invalid_password} = Vault.unlock("wrongpass")
    assert Vault.status() == :locked

    # Unlock with correct password
    assert {:ok, :unlocked} = Vault.unlock("secret123")
    assert Vault.status() == :unlocked
    assert {:ok, "my-ssh-private-key-data"} = Vault.decrypt(ciphertext)
  end
end
