defmodule SSHClient.Config.ServerMultiUserTest do
  use ExUnit.Case, async: true

  alias SSHClient.Config.Server

  describe "from_map/1 with multi-user and auth method" do
    test "defaults users list to [user] when users field is omitted" do
      attrs = %{
        "id" => "srv1",
        "host" => "192.168.1.10",
        "user" => "ubuntu"
      }

      assert {:ok, server} = Server.from_map(attrs)
      assert server.user == "ubuntu"
      assert server.users == ["ubuntu"]
      assert server.default_auth_method == :key
    end

    test "parses users list and preserves default user" do
      attrs = %{
        "id" => "srv2",
        "host" => "192.168.1.20",
        "user" => "ubuntu",
        "users" => ["ubuntu", "root", "deploy"],
        "default_auth_method" => "password"
      }

      assert {:ok, server} = Server.from_map(attrs)
      assert server.user == "ubuntu"
      assert server.users == ["ubuntu", "root", "deploy"]
      assert server.default_auth_method == :password
    end

    test "parses comma-separated string for users" do
      attrs = %{
        "id" => "srv3",
        "host" => "192.168.1.30",
        "user" => "admin",
        "users" => "admin, root, developer",
        "auth_method" => "password"
      }

      assert {:ok, server} = Server.from_map(attrs)
      assert server.user == "admin"
      assert server.users == ["admin", "root", "developer"]
      assert server.default_auth_method == :password
    end

    test "derives primary user from first element of users when user is omitted" do
      attrs = %{
        "id" => "srv4",
        "host" => "192.168.1.40",
        "users" => ["root", "backup"]
      }

      assert {:ok, server} = Server.from_map(attrs)
      assert server.user == "root"
      assert server.users == ["root", "backup"]
    end
  end
end
