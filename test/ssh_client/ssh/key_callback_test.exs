defmodule SSHClient.SSH.KeyCallbackTest do
  use ExUnit.Case, async: true
  alias SSHClient.SSH.KeyCallback

  test "loads a nonstandard identity from real OTP nested callback options" do
    path = Path.expand("test/fixtures/docker/ssh-target/id_ed25519")

    assert {:ok, key} =
             KeyCallback.user_key(:"ssh-ed25519", key_cb_private: [identity_file: path])

    assert is_tuple(key)
  end

  test "an explicit missing identity never falls back to a different key" do
    assert {:error, {:identity_file, :enoent}} =
             KeyCallback.user_key(:"ssh-ed25519",
               key_cb_private: [identity_file: "missing-selected-identity"]
             )
  end

  test "decrypts a selected PEM identity and rejects an incorrect passphrase" do
    path = Path.join(System.tmp_dir!(), "identity-#{System.unique_integer([:positive])}")
    key = :public_key.generate_key({:rsa, 2048, 65_537})

    entry =
      :public_key.pem_entry_encode(
        :RSAPrivateKey,
        key,
        {{~c"AES-256-CBC", :crypto.strong_rand_bytes(16)}, ~c"correct"}
      )

    File.write!(path, :public_key.pem_encode([entry]))
    on_exit(fn -> File.rm(path) end)

    assert {:ok, ^key} =
             KeyCallback.user_key(:"rsa-sha2-256",
               key_cb_private: [identity_file: path, passphrase: "correct"]
             )

    assert {:error, {:identity_file, _}} =
             KeyCallback.user_key(:"rsa-sha2-256",
               key_cb_private: [identity_file: path, passphrase: "wrong"]
             )
  end
end
