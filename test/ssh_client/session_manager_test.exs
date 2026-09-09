defmodule SSHClient.SessionManagerTest do
  use ExUnit.Case, async: false

  alias SSHClient.Config.Server
  alias SSHClient.SessionManager

  setup do
    server = %Server{
      id: "test-srv-#{System.unique_integer([:positive])}",
      host: "127.0.0.1",
      port: 22,
      user: "testuser"
    }

    %{server: server}
  end

  describe "lifecycle management" do
    test "creates, lists, retrieves, and closes session workers", %{server: server} do
      {:ok, session_id} = SessionManager.create_session(server, auto_connect: false)
      assert is_binary(session_id)
      assert SessionManager.has_session?(session_id)

      {:ok, pid} = SessionManager.get_session(session_id)
      assert is_pid(pid)
      assert Process.alive?(pid)

      sessions = SessionManager.list_sessions()
      assert Enum.any?(sessions, fn s -> s.session_id == session_id and s.pid == pid end)

      session_item = Enum.find(sessions, fn s -> s.session_id == session_id end)
      assert session_item.server == server
      assert session_item.status == :disconnected
      assert %DateTime{} = session_item.created_at

      :ok = SessionManager.close_session(session_id)
      refute SessionManager.has_session?(session_id)
      assert SessionManager.get_session(session_id) == {:error, :not_found}
      refute Process.alive?(pid)
    end

    test "allows custom session_id", %{server: server} do
      custom_id = "custom-session-#{System.unique_integer([:positive])}"

      {:ok, session_id} =
        SessionManager.create_session(server, session_id: custom_id, auto_connect: false)

      assert session_id == custom_id
      assert SessionManager.has_session?(custom_id)

      SessionManager.close_session(custom_id)
      refute SessionManager.has_session?(custom_id)
    end

    test "returns error when closing non-existent session" do
      assert SessionManager.close_session("non-existent-session-id") == {:error, :not_found}
    end

    test "returns error when retrieving non-existent session" do
      assert SessionManager.get_session("non-existent-session-id") == {:error, :not_found}
      refute SessionManager.has_session?("non-existent-session-id")
    end

    test "cleans up automatically when worker crashes", %{server: server} do
      {:ok, session_id} = SessionManager.create_session(server, auto_connect: false)
      {:ok, pid} = SessionManager.get_session(session_id)

      Process.exit(pid, :kill)
      Process.sleep(50)

      refute SessionManager.has_session?(session_id)
      assert SessionManager.get_session(session_id) == {:error, :not_found}
      refute Enum.any?(SessionManager.list_sessions(), fn s -> s.session_id == session_id end)
    end

    test "list_for_server filters by host id", %{server: server} do
      {:ok, session_id} = SessionManager.create_session(server, auto_connect: false)
      other = %{server | id: server.id <> "-other"}
      {:ok, other_id} = SessionManager.create_session(other, auto_connect: false)

      ids = Enum.map(SessionManager.list_for_server(server.id), & &1.session_id)
      assert session_id in ids
      refute other_id in ids

      SessionManager.close_session(session_id)
      SessionManager.close_session(other_id)
    end
  end
end
