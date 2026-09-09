defmodule SSHClient.SSH.KeyManagerTest do
  use ExUnit.Case, async: true

  alias SSHClient.SSH.KeyManager

  @temp_dir Path.join(
              System.tmp_dir!(),
              "ssh_client_km_test_#{:erlang.unique_integer([:positive])}"
            )

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
