defmodule SSHClientWeb.TerminalLiveTest do
  use ExUnit.Case, async: true

  alias SSHClient.Terminal.Layout
  alias SSHClientWeb.TerminalLive

  test "module is defined and compiled" do
    assert Code.ensure_loaded?(TerminalLive)
  end

  defp build_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.put(assigns, :__changed__, %{})
    }
  end

  describe "deploy key modal events" do
    test "dismiss_deploy_modal dismisses the prompt" do
      socket =
        build_socket(%{
          show_deploy_modal: true,
          deploy_status: :idle
        })

      assert {:noreply, updated} = TerminalLive.handle_event("dismiss_deploy_modal", %{}, socket)
      assert updated.assigns.show_deploy_modal == false
      assert updated.assigns.deploy_status == :dismissed
    end

    test "deploy_ssh_key handles nil key or server gracefully" do
      socket =
        build_socket(%{
          show_deploy_modal: true,
          deploy_key_info: nil,
          server: nil
        })

      assert {:noreply, _} = TerminalLive.handle_event("deploy_ssh_key", %{}, socket)
    end
  end

  describe "shortcuts modal events" do
    test "toggle_shortcuts and close_shortcuts manage shortcuts modal visibility" do
      socket = build_socket(%{show_shortcuts_modal: false})
      assert {:noreply, updated} = TerminalLive.handle_event("toggle_shortcuts", %{}, socket)
      assert updated.assigns.show_shortcuts_modal == true

      assert {:noreply, closed} = TerminalLive.handle_event("close_shortcuts", %{}, updated)
      assert closed.assigns.show_shortcuts_modal == false
    end
  end

  describe "pane_ready hook event" do
    test "does not crash and keeps the existing pane session" do
      session_id = "pane-sess-1"

      socket =
        build_socket(%{
          tabs: [
            %{
              id: 1,
              title: "Shell 1",
              session_id: session_id,
              session_pid: nil,
              connected: false,
              error: nil,
              status: :connecting,
              layout: Layout.new(session_id)
            }
          ],
          active_tab_id: 1,
          active_pane_id: session_id,
          server: nil,
          server_id: "henry",
          cols: 80,
          rows: 24,
          target_user: nil,
          target_auth: nil
        })

      assert {:noreply, updated} =
               TerminalLive.handle_event("pane_ready", %{"pane_id" => session_id}, socket)

      tab = hd(updated.assigns.tabs)
      assert tab.session_id == session_id
      assert tab.status == :connecting
      refute tab.connected
      assert updated.assigns.active_pane_id == session_id
    end

    test "starts a session when none exists and records a missing-host error" do
      socket =
        build_socket(%{
          tabs: [
            %{
              id: 1,
              title: "Shell 1",
              session_id: nil,
              session_pid: nil,
              connected: false,
              error: nil,
              status: :disconnected,
              layout: nil
            }
          ],
          active_tab_id: 1,
          active_pane_id: nil,
          server: nil,
          server_id: "henry",
          cols: 80,
          rows: 24,
          target_user: nil,
          target_auth: nil
        })

      assert {:noreply, updated} =
               TerminalLive.handle_event("pane_ready", %{"pane_id" => "missing"}, socket)

      tab = hd(updated.assigns.tabs)
      assert tab.status == :error
      assert tab.error =~ "not found"
      refute tab.connected
    end

    test "is a no-op when there is no active tab" do
      socket =
        build_socket(%{
          tabs: [],
          active_tab_id: 1,
          active_pane_id: nil,
          server: nil,
          server_id: "henry"
        })

      assert {:noreply, updated} = TerminalLive.handle_event("pane_ready", %{}, socket)
      assert updated.assigns.tabs == []
    end

    test "unknown pane_id does not replace an existing session" do
      session_id = "pane-sess-keep"

      socket =
        build_socket(%{
          tabs: [
            %{
              id: 1,
              title: "Shell 1",
              session_id: session_id,
              session_pid: nil,
              connected: true,
              error: nil,
              status: :connected,
              layout: Layout.new(session_id)
            }
          ],
          active_tab_id: 1,
          active_pane_id: session_id,
          server: nil,
          server_id: "henry",
          cols: 80,
          rows: 24,
          target_user: nil,
          target_auth: nil
        })

      assert {:noreply, updated} =
               TerminalLive.handle_event("pane_ready", %{"pane_id" => "unknown-pane"}, socket)

      tab = hd(updated.assigns.tabs)
      assert tab.session_id == session_id
      assert tab.status == :connected
      assert tab.connected
    end
  end

  describe "session worker integration" do
    test "reconnect without a live session does not crash" do
      socket =
        build_socket(%{
          tabs: [
            %{
              id: 1,
              title: "Shell 1",
              session_id: nil,
              session_pid: nil,
              connected: false,
              error: nil,
              layout: nil
            }
          ],
          active_tab_id: 1,
          active_pane_id: nil,
          server: nil,
          server_id: "missing",
          cols: 80,
          rows: 24,
          target_user: nil,
          target_auth: nil
        })

      assert {:noreply, updated} = TerminalLive.handle_event("reconnect", %{}, socket)
      tab = hd(updated.assigns.tabs)
      assert tab.error =~ "not found"
    end
  end

  describe "host key and maximize" do
    test "reject_host_key clears prompt" do
      socket = build_socket(%{host_key_prompt: %{type: :new_host_key, details: %{}}})
      assert {:noreply, updated} = TerminalLive.handle_event("reject_host_key", %{}, socket)
      assert updated.assigns.host_key_prompt == nil
    end

    test "maximize_pane is a no-op without layout" do
      socket =
        build_socket(%{
          tabs: [%{id: 1, layout: nil, session_id: nil}],
          active_tab_id: 1,
          active_pane_id: nil
        })

      assert {:noreply, updated} = TerminalLive.handle_event("maximize_pane", %{}, socket)
      assert hd(updated.assigns.tabs).layout == nil
    end
  end

  describe "active session rendering" do
    test "render/1 renders active terminal wrapped in sidebar app_shell" do
      assigns = %{
        server_id: "prod-node-1",
        server: nil,
        servers: [%{id: "prod-node-1", name: "Production Node 1", host: "10.0.0.1"}],
        online_count: 1,
        version: "0.0.43",
        tabs: [
          %{
            id: 1,
            title: "Shell 1",
            connected: true,
            error: nil,
            layout: nil
          }
        ],
        active_tab_id: 1,
        cols: 80,
        rows: 24,
        show_commands: false,
        all_commands: [],
        selected_category: "all",
        command_search: "",
        show_deploy_modal: false,
        host_key_prompt: nil,
        command_palette_open: false,
        flash: %{}
      }

      html = Phoenix.LiveViewTest.rendered_to_string(TerminalLive.render(assigns))
      assert html =~ "prod-node-1"
      assert html =~ "href=\"/terminal\""
      assert html =~ "href=\"/\""
      assert html =~ "w-14"
      assert html =~ "Keyboard Shortcuts"

      modal_html =
        Phoenix.LiveViewTest.rendered_to_string(
          TerminalLive.render(Map.put(assigns, :show_shortcuts_modal, true))
        )

      assert modal_html =~ "Keyboard Shortcuts"
      assert modal_html =~ "Command Palette"
      assert modal_html =~ "Ctrl + Shift + ?"
    end

    test "render/1 uses a TerminalPane hook with phx-update ignore when a layout exists" do
      session_id = "pane-layout-1"

      assigns = %{
        server_id: "henry",
        server: nil,
        servers: [%{id: "henry", name: "henry", host: "10.0.0.8"}],
        online_count: 0,
        version: "0.0.54",
        tabs: [
          %{
            id: 1,
            title: "Shell 1",
            connected: false,
            error: nil,
            layout: Layout.new(session_id),
            session_id: session_id
          }
        ],
        active_tab_id: 1,
        cols: 80,
        rows: 24,
        show_commands: false,
        all_commands: [],
        selected_category: "all",
        command_search: "",
        show_deploy_modal: false,
        host_key_prompt: nil,
        command_palette_open: false,
        flash: %{}
      }

      html = Phoenix.LiveViewTest.rendered_to_string(TerminalLive.render(assigns))
      assert html =~ "phx-hook=\"TerminalPane\""
      assert html =~ "id=\"terminal-pane-#{session_id}\""
      assert html =~ "data-session-id=\"#{session_id}\""
      assert html =~ "phx-update=\"ignore\""
      refute html =~ "id=\"xterm-container\""
    end
  end
end
