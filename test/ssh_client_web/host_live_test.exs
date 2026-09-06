defmodule SSHClientWeb.HostLiveTest do
  use ExUnit.Case, async: true

  alias SSHClientWeb.HostLive

  test "filter_servers returns all servers when query is empty" do
    servers = [
      %{id: "srv-1", name: "Production Web Alpha", host: "10.0.0.1"},
      %{id: "srv-2", name: "Database Master", host: "10.0.0.2"},
      %{id: "srv-3", name: "Staging Redis", host: "10.0.0.3"}
    ]

    assert length(HostLive.filter_servers(servers, "")) == 3
  end

  test "filter_servers filters by name substring" do
    servers = [
      %{id: "srv-1", name: "Production Web", host: "10.0.0.1"},
      %{id: "srv-2", name: "Database Master", host: "10.0.0.2"}
    ]

    result = HostLive.filter_servers(servers, "production")
    assert length(result) == 1
    assert hd(result).id == "srv-1"
  end

  test "filter_servers returns empty list when nothing matches" do
    servers = [
      %{id: "srv-1", name: "Web Alpha", host: "10.0.0.1"}
    ]

    assert HostLive.filter_servers(servers, "zzznomatch") == []
  end

  test "fuzzy_score returns high score for exact match" do
    server = %{id: "db", name: "Database", host: "10.0.0.1"}
    assert HostLive.fuzzy_score(server, "database") == 1000
  end

  test "fuzzy_score returns 0 for no match" do
    server = %{id: "web", name: "Web Alpha", host: "10.0.0.1"}
    assert HostLive.fuzzy_score(server, "zzznomatch") == 0
  end

  defp build_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.put(assigns, :__changed__, %{})
    }
  end

  describe "connect modal event handlers" do
    test "open_connect_modal assigns server, users, and auth method" do
      server = %{
        id: "srv-multi",
        name: "Cluster Node",
        host: "10.0.0.10",
        port: 22,
        user: "ubuntu",
        users: ["ubuntu", "root", "deploy"],
        default_auth_method: :password
      }

      socket =
        build_socket(%{
          servers: [server],
          connect_modal: false,
          connect_server: nil,
          connect_user: "",
          connect_users: [],
          connect_auth_method: :key,
          connect_password: "",
          connect_remember: true,
          has_saved_password: false,
          custom_user: ""
        })

      assert {:noreply, updated} = HostLive.handle_event("open_connect_modal", %{"id" => "srv-multi"}, socket)
      assert updated.assigns.connect_modal == true
      assert updated.assigns.connect_server == server
      assert updated.assigns.connect_user == "ubuntu"
      assert updated.assigns.connect_users == ["ubuntu", "root", "deploy"]
      assert updated.assigns.connect_auth_method == :password
    end

    test "close_connect_modal resets modal state" do
      socket =
        build_socket(%{
          connect_modal: true,
          connect_server: %{id: "srv-multi"},
          error: "some error"
        })

      assert {:noreply, updated} = HostLive.handle_event("close_connect_modal", %{}, socket)
      assert updated.assigns.connect_modal == false
      assert updated.assigns.connect_server == nil
      assert updated.assigns.error == nil
    end

    test "select_connect_user switches target user" do
      socket =
        build_socket(%{
          connect_server: %{id: "srv-multi"},
          connect_user: "ubuntu",
          has_saved_password: false
        })

      assert {:noreply, updated} = HostLive.handle_event("select_connect_user", %{"user" => "root"}, socket)
      assert updated.assigns.connect_user == "root"
    end

    test "set_connect_auth_method switches auth method" do
      socket =
        build_socket(%{
          connect_auth_method: :key
        })

      assert {:noreply, updated} = HostLive.handle_event("set_connect_auth_method", %{"method" => "password"}, socket)
      assert updated.assigns.connect_auth_method == :password

      assert {:noreply, updated_key} = HostLive.handle_event("set_connect_auth_method", %{"method" => "key"}, updated)
      assert updated_key.assigns.connect_auth_method == :key
    end
  end

  describe "add server modal event handlers" do
    test "form_change preserves typed form values across renders" do
      socket =
        build_socket(%{
          new_name: "",
          new_host: "",
          new_user: "",
          new_port: "22",
          new_users: "",
          new_auth_method: "key",
          new_password: "",
          new_remember_password: true
        })

      params = %{
        "name" => "Staging Redis",
        "host" => "192.168.1.50",
        "user" => "deploy",
        "port" => "2222",
        "users" => "deploy, admin",
        "auth_method" => "password",
        "password" => "test-pwd",
        "remember_password" => "true"
      }

      assert {:noreply, updated} = HostLive.handle_event("form_change", params, socket)
      assert updated.assigns.new_name == "Staging Redis"
      assert updated.assigns.new_host == "192.168.1.50"
      assert updated.assigns.new_user == "deploy"
      assert updated.assigns.new_port == "2222"
      assert updated.assigns.new_users == "deploy, admin"
      assert updated.assigns.new_auth_method == "password"
      assert updated.assigns.new_password == "test-pwd"
      assert updated.assigns.new_remember_password == true
    end

    test "open_add_modal and close_add_modal reset form assigns" do
      socket =
        build_socket(%{
          add_modal: true,
          error: "Some error",
          new_name: "Dirty Name",
          new_host: "10.0.0.1",
          new_user: "root",
          new_port: "22",
          new_users: "root",
          new_auth_method: "password",
          new_password: "test-pwd",
          new_remember_password: true
        })

      assert {:noreply, closed} = HostLive.handle_event("close_add_modal", %{}, socket)
      assert closed.assigns.add_modal == false
      assert is_nil(closed.assigns.error)
      assert closed.assigns.new_name == ""
      assert closed.assigns.new_host == ""
      assert closed.assigns.new_user == ""
      assert closed.assigns.new_password == ""

      assert {:noreply, reopened} = HostLive.handle_event("open_add_modal", %{}, closed)
      assert reopened.assigns.add_modal == true
      assert reopened.assigns.new_name == ""
      assert reopened.assigns.new_host == ""
      assert reopened.assigns.new_user == ""
      assert reopened.assigns.new_password == ""
    end

    test "add_server with password stores credentials in Keychain" do
      params = %{
        "name" => "Secured Vault",
        "host" => "192.168.5.10",
        "user" => "appuser",
        "port" => "22",
        "users" => "",
        "auth_method" => "password",
        "password" => "test-pwd",
        "remember_password" => "true"
      }

      socket =
        build_socket(%{
          servers: [],
          add_modal: true,
          error: nil,
          new_name: "Secured Vault",
          new_host: "192.168.5.10",
          new_user: "appuser",
          new_port: "22",
          new_users: "",
          new_auth_method: "password",
          new_password: "test-pwd",
          new_remember_password: true
        })

      assert {:noreply, updated} = HostLive.handle_event("add_server", params, socket)
      assert updated.assigns.add_modal == false

      assert {:ok, "test-pwd"} = SSHClient.Keychain.retrieve("appuser@secured-vault")
    end
  end
end
