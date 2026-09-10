defmodule SSHClientWeb.SplitTerminalTest do
  use ExUnit.Case, async: false

  alias SSHClient.Config.Server
  alias SSHClient.SessionManager
  alias SSHClient.Terminal.Layout
  alias SSHClientWeb.HostLive

  setup do
    server = %Server{
      id: "srv-node-#{System.unique_integer([:positive])}",
      name: "App Node 1",
      host: "127.0.0.1",
      port: 22,
      user: "deploy"
    }

    %{server: server}
  end

  defp build_socket(assigns) do
    base = %{
      page_title: "ssh-client",
      servers: [],
      tabs: [],
      active_tab_id: nil,
      active_pane_id: nil,
      next_tab_id: 1,
      __changed__: %{}
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(base, assigns),
      endpoint: SSHClientWeb.Endpoint
    }
  end

  describe "terminal multi-tab and split-pane events" do
    test "open_terminal creates initial tab and session worker", %{server: server} do
      socket = build_socket(%{servers: [server]})

      assert {:noreply, updated} =
               HostLive.handle_event(
                 "open_terminal",
                 %{"id" => server.id, "auto_connect" => false},
                 socket
               )

      assert length(updated.assigns.tabs) == 1
      tab = hd(updated.assigns.tabs)
      assert tab.id == 1
      assert tab.title == server.name
      assert %Layout{type: :single} = tab.layout
      assert length(Layout.panes(tab.layout)) == 1
      assert updated.assigns.active_tab_id == 1

      pane_id = Layout.active_pane(tab.layout)
      assert updated.assigns.active_pane_id == pane_id
      assert SessionManager.has_session?(pane_id)

      on_exit(fn ->
        SessionManager.close_session(pane_id)
      end)
    end

    test "split_right creates a new independent SessionWorker and updates layout to split_h", %{
      server: server
    } do
      socket = build_socket(%{servers: [server]})

      {:noreply, socket} =
        HostLive.handle_event(
          "open_terminal",
          %{"id" => server.id, "auto_connect" => false},
          socket
        )

      initial_tab = hd(socket.assigns.tabs)
      sess_1 = Layout.active_pane(initial_tab.layout)

      assert {:noreply, split_socket} =
               HostLive.handle_event("split_right", %{"auto_connect" => false}, socket)

      updated_tab = hd(split_socket.assigns.tabs)
      assert updated_tab.layout.type == :split_h
      panes = Layout.panes(updated_tab.layout)
      assert length(panes) == 2
      assert hd(panes) == sess_1
      sess_2 = List.last(panes)

      assert sess_1 != sess_2
      assert SessionManager.has_session?(sess_1)
      assert SessionManager.has_session?(sess_2)
      assert split_socket.assigns.active_pane_id == sess_2
      assert Layout.active_pane(updated_tab.layout) == sess_2

      on_exit(fn ->
        SessionManager.close_session(sess_1)
        SessionManager.close_session(sess_2)
      end)
    end

    test "split_down creates a new independent SessionWorker and updates layout to split_v", %{
      server: server
    } do
      socket = build_socket(%{servers: [server]})

      {:noreply, socket} =
        HostLive.handle_event(
          "open_terminal",
          %{"id" => server.id, "auto_connect" => false},
          socket
        )

      initial_tab = hd(socket.assigns.tabs)
      sess_1 = Layout.active_pane(initial_tab.layout)

      assert {:noreply, split_socket} =
               HostLive.handle_event("split_down", %{"auto_connect" => false}, socket)

      updated_tab = hd(split_socket.assigns.tabs)
      assert updated_tab.layout.type == :split_v
      panes = Layout.panes(updated_tab.layout)
      assert length(panes) == 2
      sess_2 = List.last(panes)

      assert sess_1 != sess_2
      assert SessionManager.has_session?(sess_1)
      assert SessionManager.has_session?(sess_2)
      assert split_socket.assigns.active_pane_id == sess_2

      on_exit(fn ->
        SessionManager.close_session(sess_1)
        SessionManager.close_session(sess_2)
      end)
    end

    test "focus_pane and focus_next_pane update active pane", %{server: server} do
      socket = build_socket(%{servers: [server]})

      {:noreply, socket} =
        HostLive.handle_event(
          "open_terminal",
          %{"id" => server.id, "auto_connect" => false},
          socket
        )

      {:noreply, socket} =
        HostLive.handle_event("split_right", %{"auto_connect" => false}, socket)

      tab = hd(socket.assigns.tabs)
      [sess_1, sess_2] = Layout.panes(tab.layout)

      assert socket.assigns.active_pane_id == sess_2

      assert {:noreply, socket} =
               HostLive.handle_event("focus_pane", %{"pane_id" => sess_1}, socket)

      assert socket.assigns.active_pane_id == sess_1
      assert Layout.active_pane(hd(socket.assigns.tabs).layout) == sess_1

      assert {:noreply, socket} =
               HostLive.handle_event("focus_next_pane", %{}, socket)

      assert socket.assigns.active_pane_id == sess_2

      on_exit(fn ->
        SessionManager.close_session(sess_1)
        SessionManager.close_session(sess_2)
      end)
    end

    test "swap_panes reorders panes in active tab layout", %{server: server} do
      socket = build_socket(%{servers: [server]})

      {:noreply, socket} =
        HostLive.handle_event(
          "open_terminal",
          %{"id" => server.id, "auto_connect" => false},
          socket
        )

      {:noreply, socket} =
        HostLive.handle_event("split_right", %{"auto_connect" => false}, socket)

      [sess_1, sess_2] = Layout.panes(hd(socket.assigns.tabs).layout)

      assert {:noreply, socket} =
               HostLive.handle_event(
                 "swap_panes",
                 %{"pane_a" => sess_1, "pane_b" => sess_2},
                 socket
               )

      assert Layout.panes(hd(socket.assigns.tabs).layout) == [sess_2, sess_1]

      on_exit(fn ->
        SessionManager.close_session(sess_1)
        SessionManager.close_session(sess_2)
      end)
    end

    test "close_pane closes session and transitions layout back to single", %{server: server} do
      socket = build_socket(%{servers: [server]})

      {:noreply, socket} =
        HostLive.handle_event(
          "open_terminal",
          %{"id" => server.id, "auto_connect" => false},
          socket
        )

      {:noreply, socket} =
        HostLive.handle_event("split_right", %{"auto_connect" => false}, socket)

      [sess_1, sess_2] = Layout.panes(hd(socket.assigns.tabs).layout)

      assert {:noreply, socket} =
               HostLive.handle_event("close_pane", %{"pane_id" => sess_2}, socket)

      tab = hd(socket.assigns.tabs)
      assert tab.layout.type == :single
      assert Layout.panes(tab.layout) == [sess_1]
      assert socket.assigns.active_pane_id == sess_1
      refute SessionManager.has_session?(sess_2)

      on_exit(fn ->
        SessionManager.close_session(sess_1)
      end)
    end

    test "switch_tab and close_tab manage multi-tab lifecycle", %{server: server} do
      server2 = %Server{
        id: "srv-node-2",
        name: "App Node 2",
        host: "127.0.0.1",
        port: 22,
        user: "root"
      }

      socket = build_socket(%{servers: [server, server2]})

      {:noreply, socket} =
        HostLive.handle_event(
          "open_terminal",
          %{"id" => server.id, "auto_connect" => false},
          socket
        )

      {:noreply, socket} =
        HostLive.handle_event(
          "new_tab",
          %{"server_id" => server2.id, "auto_connect" => false},
          socket
        )

      assert length(socket.assigns.tabs) == 2
      assert socket.assigns.active_tab_id == 2

      # Switch to tab 1
      assert {:noreply, socket} = HostLive.handle_event("switch_tab", %{"id" => "1"}, socket)
      assert socket.assigns.active_tab_id == 1

      # Close tab 2
      tab2 = Enum.find(socket.assigns.tabs, &(&1.id == 2))
      pane_2 = Layout.active_pane(tab2.layout)

      assert {:noreply, socket} = HostLive.handle_event("close_tab", %{"id" => "2"}, socket)
      assert length(socket.assigns.tabs) == 1
      refute SessionManager.has_session?(pane_2)

      on_exit(fn ->
        tab1 = hd(socket.assigns.tabs)
        SessionManager.close_session(Layout.active_pane(tab1.layout))
      end)
    end

    test "forwards terminal data and resize events to active session", %{server: server} do
      socket = build_socket(%{servers: [server]})

      {:noreply, socket} =
        HostLive.handle_event(
          "open_terminal",
          %{"id" => server.id, "auto_connect" => false},
          socket
        )

      pane_id = socket.assigns.active_pane_id

      # Forward data
      assert {:noreply, _} =
               HostLive.handle_event("terminal_data", %{"data" => "whoami\n"}, socket)

      # Forward resize
      assert {:noreply, _} =
               HostLive.handle_event("terminal_resize", %{"cols" => 100, "rows" => 30}, socket)

      on_exit(fn ->
        SessionManager.close_session(pane_id)
      end)
    end

    test "handles pubsub pty_output and pushes event", %{server: server} do
      socket = build_socket(%{servers: [server]})

      {:noreply, socket} =
        HostLive.handle_event(
          "open_terminal",
          %{"id" => server.id, "auto_connect" => false},
          socket
        )

      pane_id = socket.assigns.active_pane_id

      # Receive pty_output pubsub message
      assert {:noreply, updated} =
               HostLive.handle_info({:pty_output, pane_id, "output data"}, socket)

      assert updated.assigns.active_pane_id == pane_id

      on_exit(fn ->
        SessionManager.close_session(pane_id)
      end)
    end

    test "persists layout to Store on open, split, maximize, and restore", %{server: server} do
      alias SSHClient.Store

      socket = build_socket(%{servers: [server]})

      {:noreply, socket} =
        HostLive.handle_event(
          "open_terminal",
          %{"id" => server.id, "auto_connect" => false},
          socket
        )

      saved = Store.get(:sessions, "host_live")
      assert saved != nil
      assert length(saved["tabs"]) == 1
      assert hd(saved["tabs"])["layout_type"] == "single"

      # Split right
      {:noreply, socket} =
        HostLive.handle_event("split_right", %{"auto_connect" => false}, socket)

      saved_split = Store.get(:sessions, "host_live")
      assert hd(saved_split["tabs"])["layout_type"] == "split_h"
      assert hd(saved_split["tabs"])["pane_count"] == 2

      # Maximize
      {:noreply, socket} = HostLive.handle_event("maximize_pane", %{}, socket)
      saved_max = Store.get(:sessions, "host_live")
      assert hd(saved_max["tabs"])["maximized"] != nil

      # Restore
      {:noreply, socket} = HostLive.handle_event("restore_panes", %{}, socket)
      saved_rest = Store.get(:sessions, "host_live")
      assert is_nil(hd(saved_rest["tabs"])["maximized"])

      # Close tab
      tab_id = to_string(hd(socket.assigns.tabs).id)
      {:noreply, _socket} = HostLive.handle_event("close_tab", %{"id" => tab_id}, socket)
      assert is_nil(Store.get(:sessions, "host_live"))
    end

    test "crash recovery restores disconnected tabs", %{server: server} do
      alias SSHClient.Store

      socket =
        build_socket(%{
          servers: [server],
          crash_recovery: %{
            tabs: [
              %{
                "id" => 1,
                "title" => server.name,
                "server_id" => server.id,
                "layout_type" => "split_h",
                "pane_count" => 2,
                "pane_ids" => ["dead-pane-1", "dead-pane-2"],
                "active_pane" => "dead-pane-1",
                "maximized" => nil
              }
            ],
            count: 1,
            workspace_id: nil,
            workspace_name: nil
          }
        })

      {:noreply, recovered} =
        HostLive.handle_event("restore_crash_session", %{"reconnect" => "false"}, socket)

      assert length(recovered.assigns.tabs) == 1
      recovered_tab = hd(recovered.assigns.tabs)
      assert recovered_tab.layout.type == :split_h
      assert length(recovered_tab.layout.panes) == 2
      assert is_nil(recovered.assigns.crash_recovery)

      Enum.each(recovered_tab.layout.panes, fn pane_id ->
        assert SessionManager.has_session?(pane_id)
        SessionManager.close_session(pane_id)
      end)
    end

    test "dismiss_crash_recovery deletes state from Store", %{server: _server} do
      alias SSHClient.Store

      Store.put(:sessions, "host_live", %{"id" => "host_live", "tabs" => []})
      assert Store.get(:sessions, "host_live") != nil

      socket = build_socket(%{crash_recovery: %{tabs: [], count: 0}})

      {:noreply, dismissed} = HostLive.handle_event("dismiss_crash_recovery", %{}, socket)
      assert is_nil(dismissed.assigns.crash_recovery)
      assert is_nil(Store.get(:sessions, "host_live"))
    end
  end
end
