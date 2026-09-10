defmodule SSHClientWeb.TerminalChannelTest do
  use ExUnit.Case, async: true

  alias SSHClientWeb.TerminalChannel

  test "wrap_bracketed_paste wraps text with terminal paste delimiters" do
    wrapped = TerminalChannel.wrap_bracketed_paste("echo line1\necho line2")
    assert String.starts_with?(wrapped, "\e[200~")
    assert String.ends_with?(wrapped, "\e[201~")
    assert wrapped =~ "echo line1\necho line2"
  end

  test "join returns status and assigns cols and rows" do
    socket = %Phoenix.Socket{
      endpoint: SSHClientWeb.Endpoint,
      topic: "terminal:srv-test",
      assigns: %{}
    }

    assert {:ok, %{status: "connected", server_id: "srv-test"}, socket} =
             TerminalChannel.join("terminal:srv-test", %{"cols" => 120, "rows" => 40}, socket)

    assert socket.assigns.server_id == "srv-test"
    assert socket.assigns.cols == 120
    assert socket.assigns.rows == 40
  end

  test "join rejects unauthorized topics" do
    socket = %Phoenix.Socket{
      endpoint: SSHClientWeb.Endpoint,
      topic: "other:srv-test",
      assigns: %{}
    }

    assert {:error, %{reason: "unauthorized"}} =
             TerminalChannel.join("other:srv-test", %{}, socket)
  end

  test "handle_in pty:resize updates assigns cols and rows" do
    socket = %Phoenix.Socket{
      endpoint: SSHClientWeb.Endpoint,
      assigns: %{cols: 80, rows: 24, session_pid: nil}
    }

    assert {:reply, :ok, updated} =
             TerminalChannel.handle_in("pty:resize", %{"cols" => 100, "rows" => 35}, socket)

    assert updated.assigns.cols == 100
    assert updated.assigns.rows == 35
  end
end
