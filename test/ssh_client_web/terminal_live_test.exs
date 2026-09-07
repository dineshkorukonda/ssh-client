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
end
