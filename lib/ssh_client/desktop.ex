defmodule SSHClient.Desktop do
  @moduledoc "Native desktop operations sharing the existing supervised SSH sessions."
  alias SSHClient.{Config, SessionManager, SessionWorker, SFTP, Store}
  alias SSHClient.Config.Server

  @host_fields ~w(id name host port user users default_auth_method identity_file proxy_jump tags notes favorite auth_order checks last_connected_at)

  def hosts do
    case Config.load_config() do
      {:ok, config} ->
        {:ok,
         Enum.map(
           config.servers,
           fn server ->
             Map.from_struct(server)
             |> Map.take(Enum.map(@host_fields, &String.to_existing_atom/1))
             |> Map.update!(:checks, fn checks -> Enum.map(checks, &Map.from_struct/1) end)
           end
         )}

      {:error, reason} ->
        if File.exists?(Config.default_config_path()), do: {:error, reason}, else: {:ok, []}
    end
  end

  def save_host(attrs) when is_map(attrs) do
    with {:ok, server} <- Server.from_map(Map.take(attrs, @host_fields)),
         {:ok, existing} <- hosts() do
      servers = Enum.map(existing, &parse_saved_host/1)
      merged = [server | Enum.reject(servers, &(&1.id == server.id))]
      Config.save_file(merged, Config.default_config_path())
    end
  end

  def delete_host(id) do
    with {:ok, existing} <- hosts() do
      existing
      |> Enum.reject(&(&1.id == id))
      |> Enum.map(&parse_saved_host/1)
      |> Config.save_file(Config.default_config_path())
    end
  end

  defp parse_saved_host(attrs) do
    {:ok, server} =
      Server.from_map(Map.new(attrs, fn {key, value} -> {to_string(key), value} end))

    server
  end

  def open_session(attrs) do
    with {:ok, server} <- Server.from_map(Map.take(attrs, @host_fields)) do
      ssh_opts =
        attrs
        |> Map.take(~w(identity_file passphrase password))
        |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)

      jump_opts =
        (attrs["jump_credentials"] || %{})
        |> Map.take(~w(user password identity_file passphrase))
        |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)

      ssh_opts =
        if jump_opts == [], do: ssh_opts, else: Keyword.put(ssh_opts, :jump_opts, jump_opts)

      SessionManager.create_session(server,
        ssh_opts: ssh_opts,
        user: attrs["user"],
        password: attrs["password"],
        auth_method: server.default_auth_method
      )
    end
  end

  def session(id, since) do
    with {:ok, worker} <- SessionManager.get_session(id),
         do: {:ok, SessionWorker.desktop_snapshot(worker, since)}
  end

  def session_action(id, action, attrs) do
    with {:ok, worker} <- SessionManager.get_session(id) do
      case action do
        "input" -> SessionWorker.send_input(worker, attrs["data"])
        "resize" -> SessionWorker.resize(worker, attrs["cols"], attrs["rows"])
        "trust" -> SessionWorker.approve_host(worker)
        "disconnect" -> SessionWorker.disconnect(worker)
        "reconnect" -> SessionWorker.reconnect(worker)
        _ -> {:error, :unknown_action}
      end
    end
  end

  def files(id, action, attrs) do
    with {:ok, worker} <- SessionManager.get_session(id),
         {:ok, conn} <- SessionWorker.connection(worker),
         {:ok, channel} <- SFTP.start_channel(conn) do
      try do
        case action do
          "list" ->
            with {:ok, entries} <- SFTP.list_dir(channel, attrs["path"] || ".") do
              {:ok, Enum.map(entries, &Map.take(&1, [:name, :path, :type, :size, :permissions]))}
            end

          "upload" ->
            SFTP.upload_file(channel, attrs["local_path"], attrs["path"])

          "download" ->
            SFTP.download_file(channel, attrs["path"], attrs["local_path"])

          "rename" ->
            SFTP.rename(channel, attrs["path"], attrs["new_path"])

          "delete" ->
            SFTP.delete_file(channel, attrs["path"])

          _ ->
            {:error, :unknown_action}
        end
      after
        SFTP.stop_channel(channel)
      end
    end
  end

  def settings, do: Store.get(:preferences, "native-desktop") || %{}

  def save_settings(attrs),
    do: Store.put(:preferences, "native-desktop", Map.take(attrs, ~w(font_size scrollback)))

  def backup do
    paths = [
      Config.default_config_path(),
      Store.default_path(),
      SSHClient.DatabasePath.default_path()
    ]

    destination = Path.join(Config.os_config_dir(), "backups/#{System.os_time(:millisecond)}")

    with :ok <- File.mkdir_p(destination) do
      results =
        for path <- paths,
            File.exists?(path),
            do: File.cp(path, Path.join(destination, Path.basename(path)))

      if Enum.all?(results, &(&1 == :ok)),
        do: {:ok, %{path: destination}},
        else: {:error, :backup_failed}
    end
  end
end
