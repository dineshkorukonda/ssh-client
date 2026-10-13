defmodule SSHClient.DesktopKeysTest do
  use ExUnit.Case, async: false
  alias SSHClient.{DesktopKeys, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "desktop-key-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    before = MapSet.new(Enum.map(DesktopKeys.list(), & &1["id"]))

    on_exit(fn ->
      for key <- DesktopKeys.list(),
          not MapSet.member?(before, key["id"]),
          do: DesktopKeys.remove(key["id"])

      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "generates a usable Ed25519 identity and stable real fingerprint", %{dir: dir} do
    path = Path.join(dir, "personal")
    assert {:ok, key} = DesktopKeys.generate(%{"path" => path})
    assert File.exists?(path <> ".pub")

    assert {:ok, [{_, _}]} =
             :ssh_file.decode_ssh_file(:private, :"ssh-ed25519", File.read!(path), :ignore)

    [_, wire | _] = String.split(key.public_key)

    assert key.fingerprint ==
             "SHA256:" <>
               Base.encode64(:crypto.hash(:sha256, Base.decode64!(wire)), padding: false)

    assert {:ok, imported} = DesktopKeys.register(%{"path" => path, "passphrase" => "not-stored"})
    assert imported.fingerprint == key.fingerprint
    persisted = Store.get(:keys, key.id) |> Jason.encode!()
    refute persisted =~ "PRIVATE KEY"
    refute persisted =~ "not-stored"
    assert {:error, _} = DesktopKeys.generate(%{"path" => path})
    assert {:ok, public} = DesktopKeys.register(%{"path" => path <> ".pub"})
    assert public.private_key_path == nil
    assert public.fingerprint == key.fingerprint
    assert :ok = DesktopKeys.remove(key.id)
    assert File.exists?(path)
  end

  @tag timeout: 60_000
  test "generates RSA-4096 and rejects malformed identities", %{dir: dir} do
    path = Path.join(dir, "rsa")
    assert {:ok, key} = DesktopKeys.generate(%{"path" => path, "algorithm" => "RSA-4096"})
    assert key.algorithm == "ssh-rsa"

    assert {:ok, [{private, _}]} =
             :ssh_file.decode_ssh_file(:private, :"ssh-rsa", File.read!(path), :ignore)

    assert elem(private, 2) |> Integer.digits(2) |> length() == 4096
    invalid = Path.join(dir, "invalid")
    File.write!(invalid, "ssh-ed25519 NOT_A_KEY")
    assert {:error, _} = DesktopKeys.register(%{"path" => invalid})
    assert {:error, _} = DesktopKeys.register(%{"path" => nil})
  end

  test "discovers only private keys in .ssh and explicit config paths without registering them",
       %{dir: dir} do
    ssh = Path.join(dir, ".ssh")
    File.mkdir_p!(ssh)
    path = Path.join(ssh, "custom-name")
    external = Path.join(dir, "outside-ssh")
    assert {:ok, _} = DesktopKeys.generate(%{"path" => path})
    assert {:ok, _} = DesktopKeys.generate(%{"path" => external})

    File.write!(
      Path.join(ssh, "config"),
      "Host test\n HostName example.com\n IdentityFile #{external}\n"
    )

    File.write!(Path.join(ssh, "known_hosts"), "not a private key")
    File.mkdir_p!(Path.join(ssh, "nested"))
    File.cp!(path, Path.join(ssh, "nested/id_ed25519"))
    File.write!(Path.join(ssh, "oversized"), String.duplicate("x", 262_145))
    before = DesktopKeys.list()
    entries = DesktopKeys.discover(home: dir)

    assert Enum.sort(Enum.map(entries, & &1.private_key_path)) ==
             Enum.sort(Enum.map([path, external], &Path.expand/1))

    assert Enum.all?(entries, &(&1.source == "local" and &1.status == "ready"))
    assert DesktopKeys.list() == before
    assert {:error, message} = DesktopKeys.inspect_file(%{"path" => path <> ".pub"})
    assert message =~ "public key"
    assert {:error, _} = DesktopKeys.inspect_file(%{"path" => ssh})
    assert {:error, _} = DesktopKeys.inspect_file(%{"path" => Path.join(ssh, "oversized")})
    assert {:error, _} = DesktopKeys.register(%{"path" => Path.join(ssh, "oversized")})
    assert DesktopKeys.discover(home: Path.join(dir, "missing")) == []
  end

  test "encrypted OpenSSH keys expose public metadata without retaining passphrases", %{dir: dir} do
    path = Path.join(dir, "encrypted")
    executable = System.find_executable("ssh-keygen")
    assert is_binary(executable)

    assert {_, 0} =
             System.cmd(executable, [
               "-t",
               "ed25519",
               "-N",
               "fixture-passphrase",
               "-f",
               path,
               "-q"
             ])

    before = DesktopKeys.list()
    assert {:ok, locked} = DesktopKeys.inspect_file(%{"path" => path})
    assert locked.status == "unsupported"
    assert locked.is_passphrase_protected
    assert locked.algorithm == "ssh-ed25519"
    assert locked.fingerprint =~ "SHA256:"
    assert {:error, _} = DesktopKeys.inspect_file(%{"path" => path, "passphrase" => "wrong"})

    assert {:error, message} =
             DesktopKeys.inspect_file(%{"path" => path, "passphrase" => "fixture-passphrase"})

    assert message =~ "bundled SSH engine"
    refute Jason.encode!(locked) =~ "fixture-passphrase"
    assert DesktopKeys.list() == before
  end

  test "encrypted PEM private keys remain selectable and validate their passphrase", %{dir: dir} do
    path = Path.join(dir, "encrypted-pem")
    key = :public_key.generate_key({:rsa, 2048, 65_537})

    pem =
      :public_key.pem_entry_encode(
        :RSAPrivateKey,
        key,
        {{~c"AES-256-CBC", :crypto.strong_rand_bytes(16)}, ~c"correct"}
      )

    File.write!(path, :public_key.pem_encode([pem]))
    public = :ssh_file.encode([{{:RSAPublicKey, elem(key, 2), elem(key, 3)}, []}], :openssh_key)
    File.write!(path <> ".pub", public)
    assert {:ok, locked} = DesktopKeys.inspect_file(%{"path" => path})
    assert locked.status == "locked"

    assert {:ok, unlocked} =
             DesktopKeys.inspect_file(%{"path" => path, "passphrase" => "correct"})

    assert unlocked.status == "ready"
    assert unlocked.fingerprint == locked.fingerprint
    assert {:error, _} = DesktopKeys.inspect_file(%{"path" => path, "passphrase" => "wrong"})
  end
end
