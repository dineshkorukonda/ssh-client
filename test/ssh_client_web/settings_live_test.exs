defmodule SSHClientWeb.SettingsLiveTest do
  use ExUnit.Case, async: true

  alias SSHClientWeb.SettingsLive

  test "export_diagnostics assigns redacted JSON" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{diagnostics_json: nil, __changed__: %{}}
    }

    assert {:noreply, updated} = SettingsLive.handle_event("export_diagnostics", %{}, socket)
    assert is_binary(updated.assigns.diagnostics_json)
    assert updated.assigns.diagnostics_json =~ "version"
  end
end
