defmodule SSHClient.CommandPalette do
  @moduledoc """
  Searchable command catalog for the global Ctrl+K palette.
  """

  @actions [
    %{id: "new_tab", label: "New Terminal", hint: "Open another session", event: "new_tab"},
    %{id: "split_right", label: "Split Right", hint: "Ctrl+Shift+\\", event: "split_right"},
    %{id: "split_down", label: "Split Down", hint: "Ctrl+Shift+-", event: "split_down"},
    %{id: "close_pane", label: "Close Pane", hint: "Ctrl+Shift+W", event: "close_pane"},
    %{
      id: "reconnect",
      label: "Reconnect",
      hint: "Restart the active SSH session",
      event: "reconnect"
    },
    %{id: "open_sftp", label: "Open SFTP", hint: "File manager", path: "/sftp"},
    %{id: "settings", label: "Settings", hint: "Updater and SSH keys", path: "/settings"},
    %{id: "logs", label: "Logs", hint: "Activity log", path: "/logs"},
    %{id: "hosts", label: "Hosts", hint: "Host list", path: "/"}
  ]

  def actions, do: @actions

  def items(servers, query) when is_list(servers) do
    q = String.downcase(query || "")

    host_items =
      Enum.map(servers, fn s ->
        id = server_field(s, :id)
        name = server_field(s, :name) || id
        user = server_field(s, :user) || "root"
        host = server_field(s, :host)

        %{
          id: "connect:#{id}",
          label: "Connect to #{name}",
          hint: "#{user}@#{host}",
          path: "/terminal/#{id}",
          event: nil
        }
      end)

    (@actions ++ host_items)
    |> Enum.filter(fn item ->
      q == "" or
        String.contains?(String.downcase(item.label), q) or
        String.contains?(String.downcase(item.hint || ""), q)
    end)
  end

  def items(_, query), do: items([], query)

  defp server_field(s, key) when is_map(s) do
    Map.get(s, key) || Map.get(s, to_string(key))
  end

  defp server_field(_, _), do: nil
end
