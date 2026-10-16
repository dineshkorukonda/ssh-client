defmodule SSHClient.Desktop do
  @moduledoc "Native desktop operations sharing the existing supervised SSH sessions."
  alias SSHClient.{Config, SessionManager, SessionWorker, SFTP, Store}
  alias SSHClient.Config.Server

  @host_fields ~w(id name host port user users default_auth_method identity_file proxy_jump tags notes favorite auth_order checks last_connected_at)

  def hosts do
    with :ok <- Store.import_hosts(Config.default_config_path()),
         hosts when is_list(hosts) <- Store.list(:hosts) do
      {:ok, hosts}
    end
  end

  def save_host(attrs) when is_map(attrs) do
    with :ok <- validate_host(attrs),
         {:ok, server} <- Server.from_map(Map.take(attrs, @host_fields)),
         {:ok, _} <- hosts() do
      Store.put(:hosts, server.id, Store.host_document(server))
    end
  end

  def delete_host(id) do
    with {:ok, _} <- hosts(), do: Store.delete(:hosts, id)
  end

  def open_session(attrs) do
    with :ok <- validate_host(attrs),
         {:ok, server} <- Server.from_map(Map.take(attrs, @host_fields)) do
      ssh_opts =
        attrs
        |> Map.take(~w(identity_file passphrase password))
        |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)

      ssh_opts = Enum.reject(ssh_opts, fn {_, value} -> is_nil(value) end)

      ssh_opts =
        case Application.get_env(:ssh_client, :desktop_known_hosts_file) do
          nil -> ssh_opts
          path -> Keyword.put(ssh_opts, :known_hosts_file, path)
        end

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

  defp validate_host(attrs) do
    strings =
      ~w(id name host user identity_file proxy_jump notes last_connected_at password passphrase)

    valid_strings =
      Enum.all?(strings, fn key ->
        is_nil(attrs[key]) or (is_binary(attrs[key]) and byte_size(attrs[key]) <= 4096)
      end)

    valid_lists =
      Enum.all?(~w(users tags), fn key ->
        is_nil(attrs[key]) or (is_list(attrs[key]) and Enum.all?(attrs[key], &is_binary/1))
      end)

    order = attrs["auth_order"]

    valid_order =
      is_nil(order) or
        (is_list(order) and
           Enum.all?(
             order,
             &(&1 in ~w(key publickey password keyboard_interactive keyboard-interactive agent))
           ))

    jump = attrs["jump_credentials"]
    valid_jump = is_nil(jump) or (is_map(jump) and Enum.all?(Map.values(jump), &is_binary/1))

    if valid_strings and valid_lists and valid_order and valid_jump,
      do: :ok,
      else: {:error, :invalid_host}
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
        "answer" -> SessionWorker.answer_auth(worker, attrs["challenge"], attrs["answers"])
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

          "mkdir" ->
            SFTP.make_dir(channel, attrs["path"])

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
    do:
      Store.put(
        :preferences,
        "native-desktop",
        Map.take(attrs, ~w(font_size font_family line_height scrollback theme reduced_motion))
      )

  def workspace, do: Store.get(:workspaces, "native-desktop") || %{"host_ids" => []}

  def workspaces do
    Enum.map(Store.list(:workspaces), fn record ->
      Map.put_new(record, "host_ids", record["server_ids"] || [])
    end)
  end

  def save_workspace(attrs) do
    layouts = attrs["layouts"] || []

    if is_list(layouts) and length(layouts) <= 100 and
         Enum.all?(layouts, fn entry ->
           is_map(entry) and is_binary(entry["host_id"]) and
             entry["host_id"] in (attrs["host_ids"] || []) and is_integer(entry["panes"]) and
             entry["panes"] in 1..8
         end) do
      Store.put(
        :workspaces,
        attrs["id"] || "native-desktop",
        Map.take(attrs, ~w(id name host_ids layouts))
      )
    else
      {:error, :invalid_workspace}
    end
  end

  def import_file(attrs) do
    selected = attrs["selected_ids"]

    with true <-
           is_nil(selected) or
             (is_list(selected) and length(selected) <= 1000 and Enum.all?(selected, &is_binary/1)),
         {:ok, preview} <- preview_import(attrs) do
      fresh =
        Enum.filter(
          preview.hosts,
          &(not &1.duplicate and (is_nil(selected) or &1.host.id in selected))
        )

      Enum.reduce_while(
        fresh,
        {:ok, %{imported: 0, skipped: length(preview.hosts) - length(fresh)}},
        fn entry, {:ok, result} ->
          case Store.put(:hosts, entry.host.id, Store.host_document(entry.host)) do
            :ok -> {:cont, {:ok, %{result | imported: result.imported + 1}}}
            error -> {:halt, error}
          end
        end
      )
    else
      false -> {:error, :invalid_selection}
      error -> error
    end
  end

  def preview_import(attrs) do
    path = attrs["path"]

    if is_binary(path) and byte_size(path) in 1..4096 do
      with {:ok, stat} <- File.stat(path),
           true <- stat.size <= 2_000_000,
           {:ok, data} <- File.read(path),
           {:ok, records} <- import_records(data, attrs["type"]),
           {:ok, servers} <- validate_import(records),
           {:ok, existing} <- hosts() do
        endpoints = MapSet.new(Enum.map(existing, &{&1["host"], &1["user"], &1["port"]}))
        ids = MapSet.new(Enum.map(existing, & &1["id"]))

        {entries, _} =
          Enum.map_reduce(servers, {ids, endpoints}, fn server, {seen_ids, seen_endpoints} ->
            endpoint = {server.host, server.user, server.port}

            duplicate =
              MapSet.member?(seen_endpoints, endpoint) or MapSet.member?(seen_ids, server.id)

            entry = %{
              host: server,
              duplicate: duplicate,
              key_missing:
                is_binary(server.identity_file) and not File.regular?(server.identity_file)
            }

            {entry, {MapSet.put(seen_ids, server.id), MapSet.put(seen_endpoints, endpoint)}}
          end)

        unsupported =
          if attrs["type"] == "ssh_config" do
            data
            |> String.split("\n")
            |> Enum.filter(
              &String.match?(&1, ~r/^\s*(Include|ProxyCommand|Match|CertificateFile)\s+/i)
            )
            |> Enum.map(&(String.split(String.trim(&1)) |> hd()))
            |> Enum.uniq()
          else
            []
          end

        {:ok, %{hosts: entries, unsupported: unsupported}}
      else
        false -> {:error, "Host import files must be smaller than 2 MB."}
        error -> error
      end
    else
      {:error, :invalid_path}
    end
  end

  defp import_records(data, "ssh_config") do
    records =
      SSHClient.SSH.ConfigImporter.parse_string(data)
      |> Enum.map(fn host ->
        %{
          "id" => host.id,
          "name" => host.name,
          "host" => host.address,
          "user" => host.user,
          "port" => host.port,
          "identity_file" => host.identity_file,
          "proxy_jump" => host.jump_host
        }
      end)

    {:ok, records}
  end

  defp import_records(data, "json") do
    case Jason.decode(data) do
      {:ok, records} when is_list(records) and length(records) <= 1000 -> {:ok, records}
      _ -> {:error, :invalid_import_file}
    end
  end

  defp import_records(_, _), do: {:error, :invalid_import_type}

  defp validate_import(records) do
    Enum.reduce_while(records, {:ok, []}, fn attrs, {:ok, acc} ->
      if is_map(attrs) do
        case with :ok <- validate_host(attrs), do: Server.from_map(Map.take(attrs, @host_fields)) do
          {:ok, server} -> {:cont, {:ok, acc ++ [server]}}
          error -> {:halt, error}
        end
      else
        {:halt, {:error, :invalid_host}}
      end
    end)
  rescue
    _ -> {:error, :invalid_host}
  end

  def backup(destination \\ nil) do
    destination =
      destination || Path.join(Config.os_config_dir(), "backups/#{System.os_time(:millisecond)}")

    with :ok <- File.mkdir_p(destination),
         :ok <- Store.backup(Path.join(destination, "app.sqlite3")) do
      database_backup = Path.join(destination, "terminal_workspaces.db")

      case Ecto.Adapters.SQL.query(SSHClient.Repo, "VACUUM INTO ?", [database_backup]) do
        {:ok, _} ->
          {:ok, %{path: destination}}

        _ ->
          {:error, :database_backup_failed}
      end
    end
  end
end
