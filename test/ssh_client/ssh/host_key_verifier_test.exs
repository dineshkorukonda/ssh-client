defmodule SSHClient.SSH.HostKeyVerifierTest do
  use ExUnit.Case, async: true

  alias SSHClient.SSH.HostKeyVerifier
  alias SSHClient.SSH.KeyCallback

  @temp_dir Path.join(System.tmp_dir!(), "host_key_test_#{System.unique_integer([:positive])}")
  @known_hosts_file Path.join(@temp_dir, "known_hosts")

  @sample_key_1 "ssh-ed25519-mock-raw-key-data-alpha"
  @sample_key_2 "ssh-ed25519-mock-raw-key-data-beta"

  setup do
    File.mkdir_p!(@temp_dir)
    File.rm_rf(@known_hosts_file)

    on_exit(fn ->
      File.rm_rf(@temp_dir)
    end)

    :ok
  end

  describe "fingerprint/1" do
    test "produces SHA256 prefixed fingerprint" do
      fp = HostKeyVerifier.fingerprint(@sample_key_1)
      assert String.starts_with?(fp, "SHA256:")
      assert String.length(fp) > 10
    end

    test "produces deterministic fingerprint for identical keys" do
      fp1 = HostKeyVerifier.fingerprint(@sample_key_1)
      fp2 = HostKeyVerifier.fingerprint(@sample_key_1)
      assert fp1 == fp2
    end
  end

  describe "verify/4 and persistence" do
    test "detects first-connect when host is not in known_hosts" do
      res =
        HostKeyVerifier.verify(@sample_key_1, "192.168.1.10", 22,
          known_hosts_file: @known_hosts_file
        )

      assert {:error, {:first_connect, details}} = res
      assert details.host == "192.168.1.10"
      assert details.port == 22
      assert String.starts_with?(details.fingerprint, "SHA256:")
    end

    test "persists key and recognizes trusted host on subsequent connection" do
      assert :ok =
               HostKeyVerifier.save_host_key("192.168.1.10", 22, @sample_key_1,
                 known_hosts_file: @known_hosts_file
               )

      res =
        HostKeyVerifier.verify(@sample_key_1, "192.168.1.10", 22,
          known_hosts_file: @known_hosts_file
        )

      assert {:ok, :trusted, details} = res
      assert details.fingerprint == HostKeyVerifier.fingerprint(@sample_key_1)
    end

    test "detects changed host key with old and new fingerprint diff" do
      assert :ok =
               HostKeyVerifier.save_host_key("192.168.1.10", 22, @sample_key_1,
                 known_hosts_file: @known_hosts_file
               )

      res =
        HostKeyVerifier.verify(@sample_key_2, "192.168.1.10", 22,
          known_hosts_file: @known_hosts_file
        )

      assert {:error, {:host_key_changed, details}} = res
      assert details.host == "192.168.1.10"
      assert details.old_fingerprint == HostKeyVerifier.fingerprint(@sample_key_1)
      assert details.new_fingerprint == HostKeyVerifier.fingerprint(@sample_key_2)
      refute details.old_fingerprint == details.new_fingerprint
    end

    test "update_host_key replaces previous fingerprint with explicit confirmation" do
      assert :ok =
               HostKeyVerifier.save_host_key("192.168.1.10", 22, @sample_key_1,
                 known_hosts_file: @known_hosts_file
               )

      assert :ok =
               HostKeyVerifier.update_host_key("192.168.1.10", 22, @sample_key_2,
                 known_hosts_file: @known_hosts_file
               )

      res =
        HostKeyVerifier.verify(@sample_key_2, "192.168.1.10", 22,
          known_hosts_file: @known_hosts_file
        )

      assert {:ok, :trusted, _} = res
    end
  end

  describe "KeyCallback integration" do
    test "tunneled destination trust uses its original identity rather than localhost" do
      refute KeyCallback.is_host_key(@sample_key_1, ~c"127.0.0.1", 45678, :"ssh-ed25519",
               key_cb_private: [
                 known_hosts_file: @known_hosts_file,
                 host_key_host: "destination",
                 host_key_port: 2222,
                 host_key_handler: self()
               ]
             )

      assert_receive {:ssh_host_key_event, :first_connect, %{host: "destination", port: 2222}}
    end

    test "nested OTP callback options deliver host-key prompts" do
      refute KeyCallback.is_host_key(@sample_key_1, ~c"new-host", 22, :"ssh-ed25519",
               key_cb_private: [known_hosts_file: @known_hosts_file, host_key_handler: self()]
             )

      assert_receive {:ssh_host_key_event, :first_connect, %{known_hosts_file: path}}
      assert path == Path.expand(@known_hosts_file)
    end

    test "trust is isolated by port and hashed OpenSSH entries are recognized" do
      assert :ok =
               HostKeyVerifier.save_host_key("host", 22, @sample_key_1,
                 known_hosts_file: @known_hosts_file
               )

      assert {:error, {:first_connect, _}} =
               HostKeyVerifier.verify(@sample_key_1, "host", 2222,
                 known_hosts_file: @known_hosts_file
               )

      salt = :crypto.strong_rand_bytes(20)
      hash = :crypto.mac(:hmac, :sha, salt, "[host]:2222")

      File.write!(
        @known_hosts_file,
        "|1|#{Base.encode64(salt)}|#{Base.encode64(hash)} ssh-ed25519 #{Base.encode64(@sample_key_1)}\n"
      )

      assert {:ok, :trusted, _} =
               HostKeyVerifier.verify(@sample_key_1, "host", 2222,
                 known_hosts_file: @known_hosts_file
               )

      assert {:error, {:first_connect, _}} =
               HostKeyVerifier.verify(@sample_key_1, "host", 22,
                 known_hosts_file: @known_hosts_file
               )
    end

    test "failed persistence never accepts a host key" do
      refute KeyCallback.is_host_key(@sample_key_1, ~c"host", 22, :"ssh-ed25519",
               key_cb_private: [known_hosts_file: @temp_dir, accept_host_key: true]
             )
    end

    test "rejects untrusted key by default and notifies handler" do
      test_pid = self()

      handler = fn event, details ->
        send(test_pid, {:host_key_event, event, details})
      end

      opts = [
        known_hosts_file: @known_hosts_file,
        host_key_handler: handler
      ]

      result = KeyCallback.is_host_key(@sample_key_1, ~c"10.0.0.5", 22, ~c"ssh-ed25519", opts)
      assert result == false

      assert_receive {:host_key_event, :first_connect, details}
      assert details.host == "10.0.0.5"
    end

    test "accepts key when accept_host_key is true and persists it" do
      opts = [
        known_hosts_file: @known_hosts_file,
        accept_host_key: true
      ]

      result = KeyCallback.is_host_key(@sample_key_1, ~c"10.0.0.5", 22, ~c"ssh-ed25519", opts)
      assert result == true

      # Should now be trusted
      assert {:ok, :trusted, _} =
               HostKeyVerifier.verify(@sample_key_1, "10.0.0.5", 22,
                 known_hosts_file: @known_hosts_file
               )
    end
  end
end
