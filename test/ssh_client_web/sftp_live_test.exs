defmodule SSHClientWeb.SFTPLiveTest do
  use ExUnit.Case, async: true

  alias SSHClientWeb.SFTPLive
  alias SSHClient.Config.Server

  describe "module compilation and callbacks" do
    test "SFTPLive module is loaded and exports standard LiveView callbacks" do
      assert Code.ensure_loaded?(SFTPLive)
      assert function_exported?(SFTPLive, :mount, 3)
      assert function_exported?(SFTPLive, :handle_info, 2)
      assert function_exported?(SFTPLive, :handle_event, 3)
      assert function_exported?(SFTPLive, :render, 1)
    end
  end

  describe "filter_entries/2" do
    setup do
      entries = [
        %{name: "nginx.conf", type: :regular, size: 1024, permissions: "0644"},
        %{name: "ssl_certificates", type: :directory, size: 0, permissions: "0755"},
        %{name: "application.log", type: :regular, size: 20480, permissions: "0644"},
        %{name: "deploy.sh", type: :regular, size: 512, permissions: "0755"}
      ]
      %{entries: entries}
    end

    test "returns all entries when filter is empty string", %{entries: entries} do
      assert SFTPLive.filter_entries(entries, "") == entries
    end

    test "filters by case-insensitive substring", %{entries: entries} do
      res = SFTPLive.filter_entries(entries, "NGINX")
      assert length(res) == 1
      assert hd(res).name == "nginx.conf"

      res2 = SFTPLive.filter_entries(entries, ".sh")
      assert length(res2) == 1
      assert hd(res2).name == "deploy.sh"
    end

    test "returns empty list when query does not match", %{entries: entries} do
      assert SFTPLive.filter_entries(entries, "nonexistent") == []
    end
  end

  describe "format_mtime/1 and pad/1" do
    test "formats date time tuple into readable string" do
      assert SFTPLive.format_mtime({{2026, 9, 6}, {1, 30, 0}}) == "2026-09-06 01:30"
      assert SFTPLive.format_mtime({{2025, 12, 25}, {14, 5, 0}}) == "2025-12-25 14:05"
    end

    test "returns fallback hyphen on invalid mtime format" do
      assert SFTPLive.format_mtime(nil) == "-"
      assert SFTPLive.format_mtime(:invalid) == "-"
    end

    test "pads numbers under 10 with leading zero" do
      assert SFTPLive.pad(0) == "00"
      assert SFTPLive.pad(5) == "05"
      assert SFTPLive.pad(9) == "09"
      assert SFTPLive.pad(10) == "10"
      assert SFTPLive.pad(42) == "42"
    end
  end

  describe "resolve_server_struct/1" do
    test "returns nil for unknown server id without raising exception" do
      assert SFTPLive.resolve_server_struct("henry_nonexistent_9999") == nil
      assert SFTPLive.resolve_server_struct("") == nil
      assert SFTPLive.resolve_server_struct(nil) == nil
    end
  end

  describe "regression: safe rendering with nil @server (GH #137 / /sftp/:id bug)" do
    test "render/1 does not crash when @server is nil" do
      assigns = %{
        __changed__: %{},
        flash: %{},
        page_title: "SFTP — henry",
        server_id: "henry",
        server: nil,
        conn: nil,
        sftp_pid: nil,
        theme: "dark",
        local_path: "/tmp",
        local_entries: [],
        local_filter: "",
        selected_local: nil,
        local_loading: false,
        remote_path: "/root",
        remote_entries: [],
        remote_filter: "",
        selected_remote: nil,
        remote_loading: false,
        error: "Host 'henry' not found in configuration.",
        transfers: [],
        active_transfer: nil,
        transfer_progress: 0,
        editor_open: false,
        editor_target: nil,
        editor_path: nil,
        editor_content: "",
        editor_saving: false,
        chmod_modal: false,
        chmod_entry: nil,
        chmod_octal: "0755",
        new_folder_modal: false,
        new_folder_target: :remote,
        new_folder_name: "",
        delete_modal: false,
        delete_target: nil,
        delete_path: nil
      }

      # Prior to the fix, this raised KeyError on nil.user
      rendered = render_to_string(SFTPLive.render(assigns))

      assert is_binary(rendered)
      assert rendered =~ "henry"
      assert rendered =~ "Host &#39;henry&#39; not found in configuration."
      assert rendered =~ "REMOTE SERVER"
    end

    test "render/1 renders properly when valid server struct is provided" do
      server = %Server{
        id: "prod-1",
        name: "Production Master",
        host: "192.168.1.50",
        user: "deploy",
        port: 22
      }

      assigns = %{
        __changed__: %{},
        flash: %{},
        page_title: "SFTP — prod-1",
        server_id: "prod-1",
        server: server,
        conn: nil,
        sftp_pid: nil,
        theme: "dark",
        local_path: "/home/user",
        local_entries: [
          %{name: "test.txt", path: "/home/user/test.txt", type: :regular, size: 100, permissions: "0644", mtime: {{2026, 9, 6}, {1, 0, 0}}}
        ],
        local_filter: "",
        selected_local: nil,
        local_loading: false,
        remote_path: "/home/deploy",
        remote_entries: [
          %{name: "app.tar.gz", path: "/home/deploy/app.tar.gz", type: :regular, size: 5000, permissions: "0644", mtime: {{2026, 9, 6}, {1, 0, 0}}}
        ],
        remote_filter: "",
        selected_remote: nil,
        remote_loading: false,
        error: nil,
        transfers: [],
        active_transfer: nil,
        transfer_progress: 0,
        editor_open: false,
        editor_target: nil,
        editor_path: nil,
        editor_content: "",
        editor_saving: false,
        chmod_modal: false,
        chmod_entry: nil,
        chmod_octal: "0755",
        new_folder_modal: false,
        new_folder_target: :remote,
        new_folder_name: "",
        delete_modal: false,
        delete_target: nil,
        delete_path: nil
      }

      rendered = render_to_string(SFTPLive.render(assigns))

      assert is_binary(rendered)
      assert rendered =~ "prod-1"
      assert rendered =~ "deploy@192.168.1.50"
      assert rendered =~ "test.txt"
      assert rendered =~ "app.tar.gz"
    end
  end

  defp render_to_string(rendered) do
    Phoenix.HTML.Safe.to_iodata(rendered) |> IO.iodata_to_binary()
  end
end
