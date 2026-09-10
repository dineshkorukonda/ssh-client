defmodule SSHClientWeb.TerminalLiveTest do
  use ExUnit.Case, async: true

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
end
