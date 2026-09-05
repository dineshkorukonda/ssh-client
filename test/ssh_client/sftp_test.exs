defmodule SSHClient.SFTPTest do
  use ExUnit.Case, async: true

  alias SSHClient.SFTP

  describe "format_size/1" do
    test "formats bytes under 1 KB" do
      assert SFTP.format_size(0) == "0 B"
      assert SFTP.format_size(512) == "512 B"
      assert SFTP.format_size(1023) == "1023 B"
    end

    test "formats kilobytes" do
      assert SFTP.format_size(1024) == "1.0 KB"
      assert SFTP.format_size(2048) == "2.0 KB"
      assert SFTP.format_size(512_000) == "500.0 KB"
    end

    test "formats megabytes" do
      assert SFTP.format_size(1_048_576) == "1.0 MB"
      assert SFTP.format_size(15_728_640) == "15.0 MB"
    end

    test "formats gigabytes" do
      assert SFTP.format_size(1_073_741_824) == "1.0 GB"
      assert SFTP.format_size(4_294_967_296) == "4.0 GB"
    end

    test "handles invalid non-integer inputs gracefully" do
      assert SFTP.format_size(nil) == "0 B"
      assert SFTP.format_size("not-a-number") == "0 B"
    end
  end

  describe "format_permissions/1" do
    test "formats standard POSIX permissions as octal strings" do
      assert SFTP.format_permissions(0o755) == "0755"
      assert SFTP.format_permissions(0o644) == "0644"
      assert SFTP.format_permissions(0o700) == "0700"
      assert SFTP.format_permissions(0o600) == "0600"
      assert SFTP.format_permissions(0o777) == "0777"
    end

    test "masks higher mode bits properly" do
      # 0o100755 (regular file with 0755 perms)
      assert SFTP.format_permissions(0o100755) == "0755"
      # 0o040755 (directory with 0755 perms)
      assert SFTP.format_permissions(0o040755) == "0755"
    end

    test "handles invalid inputs gracefully" do
      assert SFTP.format_permissions(nil) == "0644"
      assert SFTP.format_permissions("invalid") == "0644"
    end
  end

  describe "normalize_path/1" do
    test "adds leading slash to relative paths" do
      assert SFTP.normalize_path("var/log") == "/var/log"
      assert SFTP.normalize_path("etc/hosts") == "/etc/hosts"
    end

    test "preserves absolute paths" do
      assert SFTP.normalize_path("/root") == "/root"
      assert SFTP.normalize_path("/home/ubuntu") == "/home/ubuntu"
    end

    test "trims whitespace and handles root" do
      assert SFTP.normalize_path("  /var/www  ") == "/var/www"
      assert SFTP.normalize_path("") == "/"
      assert SFTP.normalize_path(nil) == "/"
    end
  end

  describe "disconnected error handling defense-in-depth" do
    test "returns {:error, :not_connected} when channel pid is nil or invalid" do
      assert SFTP.list_dir(nil, "/root") == {:error, :not_connected}
      assert SFTP.read_file(nil, "/etc/issue") == {:error, :not_connected}
      assert SFTP.write_file(nil, "/tmp/test.txt", "data") == {:error, :not_connected}
      assert SFTP.upload_file(nil, "local.txt", "/remote.txt") == {:error, :not_connected}
      assert SFTP.download_file(nil, "/remote.txt", "local.txt") == {:error, :not_connected}
      assert SFTP.delete_file(nil, "/remote.txt") == {:error, :not_connected}
      assert SFTP.delete_dir(nil, "/remote_dir") == {:error, :not_connected}
      assert SFTP.make_dir(nil, "/remote_dir") == {:error, :not_connected}
      assert SFTP.rename(nil, "/old.txt", "/new.txt") == {:error, :not_connected}
    end

    test "stop_channel handles nil and dead pids safely" do
      assert SFTP.stop_channel(nil) == :ok
      assert SFTP.stop_channel(:invalid_atom) == :ok
    end
  end
end
