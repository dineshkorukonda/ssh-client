defmodule SSHClient.SSH.KeyDeployerTest do
  use ExUnit.Case, async: true

  alias SSHClient.SSH.KeyDeployer

  test "builds idempotent POSIX install script with proper directory and file permissions" do
    pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGf user@box"
    {:ok, script} = KeyDeployer.build_install_script(pub_key)

    assert String.contains?(script, "mkdir -p ~/.ssh")
    assert String.contains?(script, "chmod 700 ~/.ssh")

    assert String.contains?(
             script,
             "grep -qxF 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGf user@box'"
           )

    assert String.contains?(script, "chmod 600 ~/.ssh/authorized_keys")
  end

  test "rejects invalid public key when building install script" do
    assert {:error, :invalid_public_key} = KeyDeployer.build_install_script("malicious; rm -rf /")
  end
end
