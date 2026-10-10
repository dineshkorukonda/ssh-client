defmodule SSHClient.PassphraseCacheTest do
  use ExUnit.Case, async: false

  alias SSHClient.PassphraseCache

  setup do
    PassphraseCache.clear_all()
    :ok
  end

  test "put/2 stores passphrase in RAM and get/1 retrieves it" do
    key = "/home/user/.ssh/id_ed25519"
    pass = "super_s3cr3t_passphrase"

    assert :ok = PassphraseCache.put(key, pass)
    assert {:ok, ^pass} = PassphraseCache.get(key)
  end

  test "get/1 returns :not_found for unentered passphrases" do
    assert {:error, :not_found} = PassphraseCache.get("/non/existent/key")
  end

  test "delete/1 removes single entry from cache" do
    PassphraseCache.put("key-1", "pass-1")
    PassphraseCache.put("key-2", "pass-2")

    assert :ok = PassphraseCache.delete("key-1")
    assert {:error, :not_found} = PassphraseCache.get("key-1")
    assert {:ok, "pass-2"} = PassphraseCache.get("key-2")
  end

  test "clear_all/0 wipes all cached passphrases" do
    PassphraseCache.put("key-1", "pass-1")
    PassphraseCache.put("key-2", "pass-2")

    assert :ok = PassphraseCache.clear_all()
    assert {:error, :not_found} = PassphraseCache.get("key-1")
    assert {:error, :not_found} = PassphraseCache.get("key-2")
  end
end
