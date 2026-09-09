defmodule SSHClient.ConfigTest do
  use ExUnit.Case, async: true

  alias SSHClient.Config
  alias SSHClient.Config.Check
  alias SSHClient.Config.Server

  @valid_yaml """
  servers:
    - id: prod-web-1
      name: Production Web 1
      host: 192.168.1.100
      user: deploy
      port: 2222
      ProxyJump: jump.example.com
      checks:
        - type: systemctl
          name: nginx
        - type: docker
          name: postgres
        - type: pm2
          name: api-worker
    - host: backup.example.com
  """

  describe "load_string/1" do
    test "parses full server configuration with ProxyJump, port, and checks" do
      assert {:ok, %Config{servers: [server1, server2]}} = Config.load_string(@valid_yaml)

      assert server1.id == "prod-web-1"
      assert server1.name == "Production Web 1"
      assert server1.host == "192.168.1.100"
      assert server1.user == "deploy"
      assert server1.port == 2222
      assert server1.proxy_jump == "jump.example.com"
      assert length(server1.checks) == 3

      assert Enum.at(server1.checks, 0) == %Check{type: :systemctl, name: "nginx"}
      assert Enum.at(server1.checks, 1) == %Check{type: :docker, name: "postgres"}
      assert Enum.at(server1.checks, 2) == %Check{type: :pm2, name: "api-worker"}

      # Minimal server defaults
      assert server2.id == "backup.example.com"
      assert server2.name == "backup.example.com"
      assert server2.host == "backup.example.com"
      assert server2.user == nil
      assert server2.port == 22
      assert server2.proxy_jump == nil
      assert server2.checks == []
    end

    test "supports snake_case proxy_jump key" do
      yaml = """
      servers:
        - host: 10.0.0.5
          proxy_jump: bastion.internal
      """

      assert {:ok, %Config{servers: [server]}} = Config.load_string(yaml)
      assert server.proxy_jump == "bastion.internal"
    end

    test "parses auth_order list when provided and defaults when omitted" do
      yaml = """
      servers:
        - host: key-then-pwd.internal
          auth_order:
            - key
            - password
        - host: default-auth.internal
      """

      assert {:ok, %Config{servers: [s1, s2]}} = Config.load_string(yaml)
      assert s1.auth_order == [:key, :password]
      assert s2.auth_order == [:key, :password, :keyboard_interactive]
    end

    test "fails fast when YAML syntax is invalid" do
      invalid_yaml = "servers: [unclosed list"
      assert {:error, message} = Config.load_string(invalid_yaml)
      assert message =~ "invalid YAML syntax"
    end

    test "fails fast when servers key is missing" do
      yaml = "other_key: 123"
      assert {:error, message} = Config.load_string(yaml)
      assert message =~ "config must contain a 'servers' key"
    end

    test "fails fast when host is missing in server entry" do
      yaml = """
      servers:
        - user: admin
      """

      assert {:error, message} = Config.load_string(yaml)
      assert message =~ "missing required field 'host'"
    end

    test "fails fast when port is invalid" do
      yaml = """
      servers:
        - host: example.com
          port: 999999
      """

      assert {:error, message} = Config.load_string(yaml)
      assert message =~ "invalid port number"
    end

    test "fails fast when check type is unsupported" do
      yaml = """
      servers:
        - host: example.com
          checks:
            - type: unknown_runner
              name: foo
      """

      assert {:error, message} = Config.load_string(yaml)
      assert message =~ "unsupported check type"
    end

    test "fails fast when check name is missing" do
      yaml = """
      servers:
        - host: example.com
          checks:
            - type: systemctl
      """

      assert {:error, message} = Config.load_string(yaml)
      assert message =~ "check is missing a valid 'name'"
    end

    test "fails fast when check type is missing or not a map" do
      assert {:error, msg1} = SSHClient.Config.Check.from_map(%{"name" => "only_name"})
      assert msg1 =~ "check is missing a valid 'type'"

      assert {:error, msg2} = SSHClient.Config.Check.from_map(%{"foo" => "bar"})
      assert msg2 =~ "check must specify 'type' and 'name'"

      assert {:error, msg3} = SSHClient.Config.Check.from_map("not a map")
      assert msg3 =~ "check must be a map"
    end

    test "Server.from_map edge cases" do
      alias SSHClient.Config.Server

      assert {:error, msg1} = Server.from_map("not a map")
      assert msg1 =~ "server entry must be a map"

      assert {:error, msg2} = Server.from_map(%{"host" => ""})
      assert msg2 =~ "server host must be a non-empty string"

      assert {:ok, s1} = Server.from_map(%{"host" => "example.com", "port" => "2222"})
      assert s1.port == 2222

      assert {:error, msg3} = Server.from_map(%{"host" => "example.com", "port" => :invalid})
      assert msg3 =~ "invalid port number"

      assert {:error, msg4} = Server.from_map(%{"host" => "example.com", "port" => "not_int"})
      assert msg4 =~ "invalid port number"

      assert {:error, msg5} =
               Server.from_map(%{"host" => "example.com", "checks" => "not_a_list"})

      assert msg5 =~ "'checks' must be a list"
    end
  end

  describe "load_string!/1" do
    test "returns config struct on valid YAML" do
      config = Config.load_string!(@valid_yaml)
      assert %Config{} = config
      assert length(config.servers) == 2
    end

    test "raises Config.Error on invalid YAML" do
      assert_raise Config.Error, ~r/missing required field 'host'/, fn ->
        Config.load_string!("servers:\n  - user: admin")
      end
    end
  end

  describe "load_file/1 and load_file!/1" do
    test "reads and parses from file path" do
      path =
        Path.join(System.tmp_dir!(), "servers_test_#{System.unique_integer([:positive])}.yaml")

      File.write!(path, @valid_yaml)

      on_exit(fn -> File.rm(path) end)

      assert {:ok, %Config{}} = Config.load_file(path)
      assert %Config{} = Config.load_file!(path)
    end

    test "returns error for nonexistent file" do
      assert {:error, message} = Config.load_file("/nonexistent/servers.yaml")
      assert message =~ "failed to read config file"
    end

    test "load_file! raises Config.Error for nonexistent file" do
      assert_raise Config.Error, ~r/failed to read config file/, fn ->
        Config.load_file!("/nonexistent/servers.yaml")
      end
    end
  end

  describe "dump_string/1 and save_file/2" do
    test "serializes config to YAML and saves to file" do
      server = %SSHClient.Config.Server{
        id: "save-srv-1",
        name: "Save Srv",
        host: "10.0.0.1",
        port: 2222,
        user: "deploy",
        checks: [%SSHClient.Config.Check{type: :systemctl, name: "nginx"}]
      }

      yaml = Config.dump_string([server])
      assert yaml =~ "save-srv-1"
      assert yaml =~ "host: 10.0.0.1"
      assert yaml =~ "port: 2222"
      assert yaml =~ "nginx"

      path = Path.join(System.tmp_dir!(), "save_test_#{System.unique_integer([:positive])}.yaml")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Config.save_file([server], path)
      assert {:ok, loaded} = Config.load_file(path)
      assert length(loaded.servers) == 1
      assert hd(loaded.servers).id == "save-srv-1"
    end

    test "serializes config to JSON and loads from JSON file" do
      server = %SSHClient.Config.Server{
        id: "json-srv-1",
        name: "JSON Srv",
        host: "10.0.0.2",
        port: 22,
        user: "root",
        proxy_jump: "jump.internal",
        checks: [%SSHClient.Config.Check{type: :docker, name: "redis"}]
      }

      json_str = Config.dump_json([server])
      assert json_str =~ "json-srv-1"
      assert json_str =~ "10.0.0.2"

      path = Path.join(System.tmp_dir!(), "save_test_#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Config.save_file([server], path)
      assert {:ok, loaded} = Config.load_file(path)
      assert length(loaded.servers) == 1
      assert hd(loaded.servers).id == "json-srv-1"
      assert hd(loaded.servers).user == "root"
      assert hd(loaded.servers).proxy_jump == "jump.internal"
      assert length(hd(loaded.servers).checks) == 1
    end

    test "round-trip saves and loads extended server attributes (users, auth_method, tags, notes, favorite, identity_file)" do
      server = %Server{
        id: "full-featured-node",
        name: "Full Featured Node",
        host: "node.internal",
        user: "admin",
        users: ["admin", "root", "dev"],
        default_auth_method: :password,
        identity_file: "~/.ssh/custom_id",
        tags: ["prod", "eu-west", "k8s"],
        notes: "Primary cluster controller",
        favorite: true,
        last_connected_at: "2026-09-09T10:00:00Z",
        port: 2222
      }

      path =
        Path.join(
          System.tmp_dir!(),
          "extended_save_test_#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(path) end)

      assert :ok = Config.save_file([server], path)
      assert {:ok, loaded} = Config.load_file(path)
      assert length(loaded.servers) == 1

      s = hd(loaded.servers)
      assert s.id == "full-featured-node"
      assert s.users == ["admin", "root", "dev"]
      assert s.default_auth_method == :password
      assert s.identity_file == "~/.ssh/custom_id"
      assert s.tags == ["prod", "eu-west", "k8s"]
      assert s.notes == "Primary cluster controller"
      assert s.favorite == true
      assert s.last_connected_at == "2026-09-09T10:00:00Z"
      assert s.port == 2222
    end

    test "default_config_path/0 returns a path" do
      path = Config.default_config_path()
      assert is_binary(path)
      assert String.ends_with?(path, "servers.json") or String.ends_with?(path, "servers.yaml")
    end

    test "os_config_dir/0 resolves an OS-appropriate directory path" do
      dir = Config.os_config_dir()
      assert is_binary(dir)
      assert String.contains?(dir, "ssh-client")
    end

    test "from_map supports atom-keyed and string-keyed maps" do
      atom_map = %{
        id: "web-1",
        name: "Web 1",
        host: "10.0.0.1",
        user: "admin",
        port: 2222
      }

      assert {:ok, server} = SSHClient.Config.Server.from_map(atom_map)
      assert server.id == "web-1"
      assert server.name == "Web 1"
      assert server.host == "10.0.0.1"
      assert server.user == "admin"
      assert server.port == 2222

      str_map = %{
        "id" => "db-1",
        "name" => "DB 1",
        "host" => "10.0.0.2",
        "user" => "postgres",
        "port" => "5432"
      }

      assert {:ok, server_str} = SSHClient.Config.Server.from_map(str_map)
      assert server_str.id == "db-1"
      assert server_str.name == "DB 1"
      assert server_str.host == "10.0.0.2"
      assert server_str.user == "postgres"
      assert server_str.port == 5432
    end
  end
end
