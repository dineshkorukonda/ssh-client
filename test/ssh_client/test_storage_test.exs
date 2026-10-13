defmodule SSHClient.TestStorageTest do
  use ExUnit.Case, async: false

  test "test application storage and default credentials cannot use the user's profile" do
    directory = SSHClient.Config.os_config_dir()
    assert String.starts_with?(directory, System.tmp_dir!())
    assert SSHClient.Keychain.detect_backend() == :memory
    state = :sys.get_state(SSHClient.Store)
    assert String.starts_with?(state.path, System.tmp_dir!())

    assert String.starts_with?(
             Path.expand(SSHClient.Config.default_config_path()),
             Path.expand(System.tmp_dir!())
           )

    account = "storage-isolation@fixture"
    assert :ok = SSHClient.Keychain.store(account, "fixture-secret")
    assert {:ok, "fixture-secret"} = SSHClient.Keychain.retrieve(account, backend: :memory)
    assert :ok = SSHClient.Keychain.delete(account)
  end
end
