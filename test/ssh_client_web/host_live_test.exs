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
end
