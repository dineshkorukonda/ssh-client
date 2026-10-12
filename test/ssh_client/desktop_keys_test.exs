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
end
