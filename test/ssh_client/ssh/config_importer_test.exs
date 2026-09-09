defmodule SSHClient.SSH.ConfigImporterTest do
  use ExUnit.Case, async: true

  alias SSHClient.Host
  alias SSHClient.SSH.ConfigImporter

  @sample_config """
  # Global settings
  Host *
      ServerAliveInterval 60
      TCPKeepAlive yes

  Host web-prod
      HostName 198.51.100.10
      User ubuntu
      Port 2222
      IdentityFile ~/.ssh/prod_id_rsa
      ProxyJump jump.example.com:22

  Host db-master db-replica
      HostName 10.0.0.50
      User postgres
      Port 5432

  Host bastion
      HostName jump.example.com
      User deploy
  """

  describe "parse_string/1" do
    test "parses Host blocks, ignores Host *, parses HostName, User, Port, ProxyJump, IdentityFile" do
      hosts = ConfigImporter.parse_string(@sample_config)

      assert length(hosts) == 4

      prod = Enum.find(hosts, &(&1.id == "web-prod"))
      assert prod.name == "web-prod"
      assert prod.address == "198.51.100.10"
      assert prod.user == "ubuntu"
      assert prod.port == 2222
      assert prod.jump_host == "jump.example.com:22"
      assert is_binary(prod.identity_file)

      db_master = Enum.find(hosts, &(&1.id == "db-master"))
      assert db_master.address == "10.0.0.50"
      assert db_master.user == "postgres"
      assert db_master.port == 5432

      db_replica = Enum.find(hosts, &(&1.id == "db-replica"))
      assert db_replica.address == "10.0.0.50"
      assert db_replica.user == "postgres"
    end
  end

  describe "deduplicate/2" do
    test "filters out newly imported hosts that match existing host ids, names, or endpoints" do
      existing = [
        %Host{
          id: "web-prod",
          name: "Production Web",
          address: "198.51.100.10",
          user: "ubuntu",
          port: 2222
        }
      ]

      imported = ConfigImporter.parse_string(@sample_config)
      filtered = ConfigImporter.deduplicate(imported, existing)

      refute Enum.any?(filtered, &(&1.id == "web-prod"))
      assert Enum.any?(filtered, &(&1.id == "bastion"))
    end
  end
end
