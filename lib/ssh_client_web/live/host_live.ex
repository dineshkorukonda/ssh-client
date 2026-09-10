defmodule SSHClientWeb.HostLive do
  @moduledoc """
  Main host list LiveView — shows all registered SSH servers with live status,
  CPU/RAM/disk metrics, one-click terminal launch, and integrated multi-tab
  and split-pane terminal topology.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}
  import SSHClientWeb.CoreComponents

  alias SSHClient.CommandPalette
  alias SSHClient.Keychain
  alias SSHClient.ServerManager
  alias SSHClient.ServerWorker
  alias SSHClient.SessionManager
  alias SSHClient.SessionWorker
  alias SSHClient.SSH.ConfigImporter
  alias SSHClient.SSH.Forwarding
  alias SSHClient.Store
  alias SSHClient.Terminal.Layout
  alias SSHClient.Updater
  alias SSHClient.Vault
  alias SSHClient.Workspace

  @refresh_interval 5_000

  # ---------------------------------------------------------------------------
  # Mount
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if not Vault.unlocked?() do
      {:ok, push_navigate(socket, to: "/lock")}
    else
      if connected?(socket) do
        :timer.send_interval(@refresh_interval, :refresh)
      end

      socket =
        socket
        |> assign(:page_title, "ssh-client")
        |> assign(:version, Updater.current_version())
        |> assign(:filter, "")
        |> assign(:add_modal, false)
        |> assign(:new_name, "")
        |> assign(:new_host, "")
        |> assign(:new_user, "")
        |> assign(:new_users, "")
        |> assign(:new_auth_method, "key")
        |> assign(:new_port, "22")
        |> assign(:new_password, "")
        |> assign(:new_remember_password, true)
        |> assign(:connect_modal, false)
        |> assign(:connect_server, nil)
        |> assign(:connect_user, "")
        |> assign(:connect_users, [])
        |> assign(:connect_auth_method, :key)
        |> assign(:connect_password, "")
        |> assign(:connect_remember, true)
        |> assign(:has_saved_password, false)
        |> assign(:custom_user, "")
        |> assign(:tabs, [])
        |> assign(:active_tab_id, nil)
        |> assign(:active_pane_id, nil)
        |> assign(:next_tab_id, 1)
        |> assign(:cols, 80)
        |> assign(:rows, 24)
        |> assign(:error, nil)
        |> assign(:command_palette_open, false)
        |> assign(:command_palette_query, "")
        |> assign(:command_palette_index, 0)
        |> assign(:workspaces, [])
        |> assign(:workspace_name, "")
        |> assign(:workspace_modal, false)
        |> assign(:active_workspace_id, nil)
        |> assign(:crash_recovery, nil)
        |> assign(:forwards, [])
        |> assign(:fwd_modal, false)
        |> assign(:fwd_type, "local")
        |> assign(:fwd_server_id, "")
        |> assign(:fwd_listen, "18080")
        |> assign(:fwd_dest_host, "127.0.0.1")
        |> assign(:fwd_dest_port, "3000")
        |> load_servers()
        |> check_crash_recovery()

      {:ok, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Host Management Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("search", %{"value" => q}, socket) do
    {:noreply, assign(socket, :filter, q)}
  end

  def handle_event("poll_now", %{"id" => id}, socket) do
    case ServerWorker.whereis(id) do
      pid when is_pid(pid) -> ServerWorker.poll_now(pid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("poll_all", _params, socket) do
    try do
      socket.assigns.servers
      |> Enum.each(fn s ->
        case ServerWorker.whereis(s.id) do
          pid when is_pid(pid) -> ServerWorker.poll_now(pid)
          _ -> :ok
        end
      end)
    rescue
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("connect", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.servers, &(&1.id == id)) do
      nil ->
        {:noreply, push_navigate(socket, to: "/terminal/#{id}")}

      server ->
        users = server.users || []

        if length(users) > 1 or server.default_auth_method == :password do
          handle_event("open_connect_modal", %{"id" => id}, socket)
        else
          user_param = if server.user, do: "?user=#{URI.encode_www_form(server.user)}", else: ""
          {:noreply, push_navigate(socket, to: "/terminal/#{id}#{user_param}")}
        end
    end
  end

  def handle_event("open_connect_modal", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.servers, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      server ->
        users =
          case server.users do
            list when is_list(list) and list != [] -> list
            _ -> if server.user, do: [server.user], else: []
          end

        primary_user = server.user || List.first(users) || ""
        auth_method = server.default_auth_method || :key

        has_saved_pwd =
          if primary_user != "" do
            match?(
              {:ok, secret} when is_binary(secret) and secret != "",
              Keychain.retrieve("#{primary_user}@#{server.id}")
            )
          else
            false
          end

        socket =
          socket
          |> assign(:connect_modal, true)
          |> assign(:connect_server, server)
          |> assign(:connect_user, primary_user)
          |> assign(:connect_users, users)
          |> assign(:connect_auth_method, auth_method)
          |> assign(:connect_password, "")
          |> assign(:connect_remember, true)
          |> assign(:has_saved_password, has_saved_pwd)
          |> assign(:custom_user, "")

        {:noreply, socket}
    end
  end

  def handle_event("close_connect_modal", _params, socket) do
    {:noreply, assign(socket, connect_modal: false, connect_server: nil, error: nil)}
  end

  def handle_event("select_connect_user", %{"user" => user}, socket) do
    server = socket.assigns.connect_server

    has_saved_pwd =
      if (server && user != "") and user != "custom" do
        match?(
          {:ok, secret} when is_binary(secret) and secret != "",
          Keychain.retrieve("#{user}@#{server.id}")
        )
      else
        false
      end

    socket =
      socket
      |> assign(:connect_user, user)
      |> assign(:has_saved_password, has_saved_pwd)

    {:noreply, socket}
  end

  def handle_event("set_connect_auth_method", %{"method" => method}, socket) do
    auth_atom = if method in ["password", :password], do: :password, else: :key
    {:noreply, assign(socket, :connect_auth_method, auth_atom)}
  end

  def handle_event("submit_connect", params, socket) do
    server = socket.assigns.connect_server

    user =
      case params["user"] do
        "custom" -> String.trim(params["custom_user"] || "")
        u when is_binary(u) and u != "" -> String.trim(u)
        _ -> socket.assigns.connect_user
      end

    user = if user == "", do: (server && server.user) || "root", else: user

    auth_method = if params["auth_method"] in ["password", :password], do: :password, else: :key
    password = params["password"] || ""
    remember = params["remember"] in ["true", true, "on"]
    action = params["action"] || "terminal"

    if server do
      if auth_method == :password and password != "" do
        SSHClient.PassphraseCache.put("password:#{user}@#{server.id}", password)
        SSHClient.PassphraseCache.put("#{user}@#{server.id}", password)

        if remember do
          Keychain.store("#{user}@#{server.id}", password)
        else
          Keychain.store("#{user}@#{server.id}", password, backend: :memory)
        end
      end

      path =
        if action == "sftp" do
          "/sftp/#{server.id}?user=#{URI.encode_www_form(user)}"
        else
          "/terminal/#{server.id}?user=#{URI.encode_www_form(user)}&auth=#{auth_method}"
        end

      {:noreply, socket |> assign(:connect_modal, false) |> push_navigate(to: path)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_add_modal", _params, socket) do
    {:noreply,
     assign(socket,
       add_modal: true,
       error: nil,
       new_name: "",
       new_host: "",
       new_user: "",
       new_users: "",
       new_auth_method: "key",
       new_port: "22",
       new_password: "",
       new_remember_password: true
     )}
  end

  def handle_event("close_add_modal", _params, socket) do
    {:noreply,
     assign(socket,
       add_modal: false,
       error: nil,
       new_name: "",
       new_host: "",
       new_user: "",
       new_users: "",
       new_auth_method: "key",
       new_port: "22",
       new_password: "",
       new_remember_password: true
     )}
  end

  def handle_event("form_change", params, socket) do
    assigns = socket.assigns
    new_auth = params["auth_method"] || Map.get(assigns, :new_auth_method, "key")
    auth_str = if new_auth in ["password", :password], do: "password", else: "key"

    {:noreply,
     socket
     |> assign(:new_name, params["name"] || Map.get(assigns, :new_name, ""))
     |> assign(:new_host, params["host"] || Map.get(assigns, :new_host, ""))
     |> assign(:new_user, params["user"] || Map.get(assigns, :new_user, ""))
     |> assign(:new_port, params["port"] || Map.get(assigns, :new_port, "22"))
     |> assign(:new_users, params["users"] || Map.get(assigns, :new_users, ""))
     |> assign(:new_auth_method, auth_str)
     |> assign(:new_password, params["password"] || Map.get(assigns, :new_password, ""))
     |> assign(:new_remember_password, params["remember_password"] in ["true", true, "on"])}
  end

  def handle_event("add_server", params, socket) do
    name = String.trim(params["name"] || socket.assigns[:new_name] || "")
    host = String.trim(params["host"] || socket.assigns[:new_host] || "")
    user = String.trim(params["user"] || socket.assigns[:new_user] || "")
    extra_users = String.trim(params["users"] || socket.assigns[:new_users] || "")

    auth_method =
      if (params["auth_method"] || socket.assigns[:new_auth_method]) in ["password", :password],
        do: "password",
        else: "key"

    password = params["password"] || socket.assigns[:new_password] || ""

    remember =
      params["remember_password"] in ["true", true, "on"] or
        socket.assigns[:new_remember_password] == true

    port =
      case Integer.parse(params["port"] || socket.assigns[:new_port] || "22") do
        {p, ""} when p in 1..65535 -> p
        _ -> 22
      end

    if name == "" or host == "" or user == "" do
      {:noreply, assign(socket, :error, "Name, host, and user are required.")}
    else
      parsed_users =
        [user | String.split(extra_users, ",", trim: true)]
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      server_id = String.downcase(String.replace(name, ~r/\s+/, "-"))

      config = %{
        "id" => server_id,
        "name" => name,
        "host" => host,
        "user" => user,
        "users" => parsed_users,
        "default_auth_method" => auth_method,
        "port" => port
      }

      case ServerManager.add_server(config) do
        {:ok, _result} ->
          if password != "" do
            if remember do
              Keychain.store("#{user}@#{server_id}", password)
            else
              Keychain.store("#{user}@#{server_id}", password, backend: :memory)
            end
          end

          {:noreply,
           socket
           |> assign(
             add_modal: false,
             error: nil,
             new_name: "",
             new_host: "",
             new_user: "",
             new_users: "",
             new_auth_method: "key",
             new_port: "22",
             new_password: "",
             new_remember_password: true
           )
           |> load_servers()}

        :ok ->
          if password != "" do
            if remember do
              Keychain.store("#{user}@#{server_id}", password)
            else
              Keychain.store("#{user}@#{server_id}", password, backend: :memory)
            end
          end

          {:noreply,
           socket
           |> assign(
             add_modal: false,
             error: nil,
             new_name: "",
             new_host: "",
             new_user: "",
             new_users: "",
             new_auth_method: "key",
             new_port: "22",
             new_password: "",
             new_remember_password: true
           )
           |> load_servers()}

        {:error, reason} ->
          {:noreply, assign(socket, :error, inspect(reason))}
      end
    end
  end

  def handle_event("scan_and_import_ssh_config", _params, socket) do
    case ConfigImporter.import_file() do
      {:ok, hosts} ->
        existing = ServerManager.list_servers()
        new_hosts = ConfigImporter.deduplicate(hosts, existing)

        Enum.each(new_hosts, fn host ->
          server_map = %{
            "id" => host.id,
            "name" => host.name || host.id,
            "host" => host.address,
            "user" => host.user,
            "port" => host.port || 22,
            "identity_file" => host.identity_file,
            "proxy_jump" => host.jump_host
          }

          ServerManager.add_server(server_map)
        end)

        msg =
          if new_hosts == [] do
            "No new hosts found in ~/.ssh/config (all #{length(hosts)} registered or none present)."
          else
            "Successfully imported #{length(new_hosts)} host(s) from ~/.ssh/config!"
          end

        socket =
          socket
          |> put_flash(:info, msg)
          |> load_servers()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to scan ~/.ssh/config: #{reason}")}
    end
  end

  def handle_event("remove_server", %{"id" => id}, socket) do
    case ServerManager.remove_server(id) do
      {:ok, _} ->
        {:noreply, load_servers(socket)}

      :ok ->
        {:noreply, load_servers(socket)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, inspect(reason))}
    end
  end

  def handle_event("duplicate_server", %{"id" => id}, socket) do
    case ServerManager.duplicate_server(id) do
      {:ok, _} -> {:noreply, load_servers(socket)}
      {:error, reason} -> {:noreply, assign(socket, :error, inspect(reason))}
    end
  end

  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    server = Enum.find(socket.assigns.servers, &(&1.id == id))

    if server do
      ServerManager.update_server(%{
        "id" => server.id,
        "name" => server.name,
        "host" => server.host,
        "user" => server.user,
        "port" => server.port,
        "favorite" => !server[:favorite]
      })
    end

    {:noreply, load_servers(socket)}
  end

  def handle_event("open_workspace_modal", _params, socket) do
    {:noreply, assign(socket, workspace_modal: true, workspace_name: "")}
  end

  def handle_event("close_workspace_modal", _params, socket) do
    {:noreply, assign(socket, workspace_modal: false)}
  end

  def handle_event("update_workspace_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :workspace_name, name)}
  end

  def handle_event("create_workspace", params, socket) do
    name = String.trim(params["name"] || socket.assigns[:workspace_name] || "")
    ids = Enum.map(socket.assigns.servers, & &1.id)

    socket =
      if name == "" do
        assign(socket, :error, "Workspace name is required.")
      else
        case Workspace.create(name, ids) do
          {:ok, _} -> assign(socket, workspace_modal: false, workspace_name: "", error: nil)
          {:error, reason} -> assign(socket, :error, inspect(reason))
        end
      end

    {:noreply, load_servers(socket)}
  end

  def handle_event("open_workspace", %{"id" => id}, socket) do
    case Workspace.get(id) do
      nil ->
        {:noreply, socket}

      ws ->
        socket = assign(socket, :active_workspace_id, id)

        socket =
          Enum.reduce(ws["server_ids"] || [], socket, fn server_id, acc ->
            case handle_event("open_terminal", %{"id" => server_id, "auto_connect" => false}, acc) do
              {:noreply, next_socket} -> next_socket
              next_socket -> next_socket
            end
          end)

        {:noreply, persist_layout(socket)}
    end
  end

  def handle_event("delete_workspace", %{"id" => id}, socket) do
    Workspace.delete(id)
    {:noreply, load_servers(socket)}
  end

  def handle_event("open_fwd_modal", _params, socket) do
    first = List.first(socket.assigns.servers)
    {:noreply, assign(socket, fwd_modal: true, fwd_server_id: first && first.id)}
  end

  def handle_event("close_fwd_modal", _params, socket) do
    {:noreply, assign(socket, fwd_modal: false)}
  end

  def handle_event("start_forward", params, socket) do
    server =
      Enum.find(
        socket.assigns.servers,
        &(&1.id == (params["server_id"] || socket.assigns.fwd_server_id))
      )

    type = if params["type"] == "remote", do: :remote, else: :local
    listen = parse_int(params["listen"] || socket.assigns.fwd_listen) || 18080
    dest_host = params["dest_host"] || socket.assigns.fwd_dest_host
    dest_port = parse_int(params["dest_port"] || socket.assigns.fwd_dest_port) || 3000

    result =
      if server do
        cfg = %{id: server.id, host: server.host, port: server.port, user: server.user}

        if type == :remote do
          Forwarding.start_remote(cfg, listen, dest_host, dest_port)
        else
          Forwarding.start_local(cfg, listen, dest_host, dest_port)
        end
      else
        {:error, :no_server}
      end

    case result do
      {:ok, _} -> {:noreply, load_servers(assign(socket, fwd_modal: false, error: nil))}
      {:error, reason} -> {:noreply, assign(socket, :error, "Forward failed: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_forward", %{"id" => id}, socket) do
    Forwarding.stop(id)
    {:noreply, load_servers(socket)}
  end

  def handle_event("lock_vault", _params, socket) do
    Vault.lock()
    {:noreply, push_navigate(socket, to: "/lock")}
  end

  # ---------------------------------------------------------------------------
  # Multi-Tab & Split-Pane Terminal Events
  # ---------------------------------------------------------------------------

  def handle_event("open_terminal", params, socket) do
    server_id = params["id"] || params["server_id"]
    server = find_server(socket, server_id)

    if server do
      auto_connect = Map.get(params, "auto_connect", true)
      opts = [auto_connect: auto_connect]

      case SessionManager.create_session(server, opts) do
        {:ok, session_id} ->
          subscribe_session(session_id)
          layout = Layout.new(session_id)
          tab_id = socket.assigns.next_tab_id

          server_name =
            cond do
              is_map(server) and Map.has_key?(server, :name) and not is_nil(server.name) ->
                server.name

              is_map(server) and Map.has_key?(server, "name") and not is_nil(server["name"]) ->
                server["name"]

              is_map(server) and Map.has_key?(server, :id) and not is_nil(server.id) ->
                server.id

              is_map(server) and Map.has_key?(server, "id") and not is_nil(server["id"]) ->
                server["id"]

              true ->
                server_id
            end

          tab = %{
            id: tab_id,
            title: server_name,
            server_id: server_id,
            server: server,
            layout: layout
          }

          socket =
            socket
            |> assign(:tabs, socket.assigns.tabs ++ [tab])
            |> assign(:active_tab_id, tab_id)
            |> assign(:active_pane_id, session_id)
            |> assign(:next_tab_id, tab_id + 1)
            |> persist_layout()

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, :error, "Failed to create session: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_tab", params, socket) do
    server_id = params["server_id"] || params["id"]

    server =
      if server_id do
        find_server(socket, server_id)
      else
        case active_tab(socket) do
          %{server: s} when not is_nil(s) -> s
          _ -> List.first(socket.assigns.servers)
        end
      end

    if server do
      target_id =
        cond do
          is_map(server) and Map.has_key?(server, :id) -> server.id
          is_map(server) and Map.has_key?(server, "id") -> server["id"]
          true -> nil
        end

      handle_event("open_terminal", Map.put(params, "id", target_id), socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("split_right", params, socket) do
    do_split(socket, :horizontal, params)
  end

  def handle_event("split_down", params, socket) do
    do_split(socket, :vertical, params)
  end

  def handle_event("focus_pane", %{"pane_id" => pane_id}, socket) do
    case active_tab(socket) do
      nil ->
        {:noreply, socket}

      tab ->
        new_layout = Layout.set_active(tab.layout, pane_id)
        updated_tab = %{tab | layout: new_layout}

        tabs =
          Enum.map(socket.assigns.tabs, fn t ->
            if t.id == tab.id, do: updated_tab, else: t
          end)

        socket =
          socket
          |> assign(:tabs, tabs)
          |> assign(:active_pane_id, Layout.active_pane(new_layout))
          |> persist_layout()

        {:noreply, socket}
    end
  end

  def handle_event("focus_next_pane", _params, socket) do
    case active_tab(socket) do
      nil ->
        {:noreply, socket}

      tab ->
        case Layout.next_pane(tab.layout) do
          nil ->
            {:noreply, socket}

          next_id ->
            handle_event("focus_pane", %{"pane_id" => next_id}, socket)
        end
    end
  end

  def handle_event("swap_panes", %{"pane_a" => pane_a, "pane_b" => pane_b}, socket) do
    case active_tab(socket) do
      nil ->
        {:noreply, socket}

      tab ->
        new_layout = Layout.swap_panes(tab.layout, pane_a, pane_b)
        updated_tab = %{tab | layout: new_layout}

        tabs =
          Enum.map(socket.assigns.tabs, fn t ->
            if t.id == tab.id, do: updated_tab, else: t
          end)

        socket =
          socket
          |> assign(:tabs, tabs)
          |> persist_layout()

        {:noreply, socket}
    end
  end

  def handle_event("close_pane", params, socket) do
    case active_tab(socket) do
      nil ->
        {:noreply, socket}

      tab ->
        pane_id = params["pane_id"] || socket.assigns.active_pane_id

        if pane_id do
          SessionManager.close_session(pane_id)
          unsubscribe_session(pane_id)

          new_layout = Layout.close_pane(tab.layout, pane_id)
          remaining_panes = Layout.panes(new_layout)

          if remaining_panes == [] do
            handle_event("close_tab", %{"id" => to_string(tab.id)}, socket)
          else
            updated_tab = %{tab | layout: new_layout}
            new_active_pane = Layout.active_pane(new_layout)

            tabs =
              Enum.map(socket.assigns.tabs, fn t ->
                if t.id == tab.id, do: updated_tab, else: t
              end)

            socket =
              socket
              |> assign(:tabs, tabs)
              |> assign(:active_pane_id, new_active_pane)
              |> persist_layout()

            {:noreply, socket}
          end
        else
          {:noreply, socket}
        end
    end
  end

  def handle_event("switch_tab", %{"id" => id_str}, socket) do
    tab_id = parse_id(id_str)
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      active_pane = Layout.active_pane(tab.layout)

      socket =
        socket
        |> assign(:active_tab_id, tab.id)
        |> assign(:active_pane_id, active_pane)
        |> persist_layout()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_tab", %{"id" => id_str}, socket) do
    tab_id = parse_id(id_str)
    target_tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if target_tab do
      Enum.each(Layout.panes(target_tab.layout), fn pane_id ->
        SessionManager.close_session(pane_id)
        unsubscribe_session(pane_id)
      end)

      remaining = Enum.reject(socket.assigns.tabs, &(&1.id == tab_id))

      socket =
        case remaining do
          [] ->
            socket
            |> assign(:tabs, [])
            |> assign(:active_tab_id, nil)
            |> assign(:active_pane_id, nil)
            |> assign(:active_workspace_id, nil)

          [first | _] ->
            new_active_tab =
              if socket.assigns.active_tab_id == tab_id do
                first
              else
                Enum.find(remaining, &(&1.id == socket.assigns.active_tab_id)) || first
              end

            socket
            |> assign(:tabs, remaining)
            |> assign(:active_tab_id, new_active_tab.id)
            |> assign(:active_pane_id, Layout.active_pane(new_active_tab.layout))
        end
        |> persist_layout()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("terminal_data", params, socket), do: send_pane_input(socket, params)

  def handle_event("pane_data", params, socket), do: send_pane_input(socket, params)

  def handle_event("terminal_resize", params, socket), do: resize_pane(socket, params)

  def handle_event("pane_resize", params, socket), do: resize_pane(socket, params)

  def handle_event("reconnect", _params, socket) do
    pane_id = socket.assigns.active_pane_id

    if pane_id do
      case SessionManager.get_session(pane_id) do
        {:ok, pid} when is_pid(pid) ->
          SessionWorker.reconnect(pid)

        _ ->
          :ok
      end
    end

    {:noreply, socket}
  end

  def handle_event("maximize_pane", _params, socket) do
    pane_id = socket.assigns.active_pane_id
    tab = active_tab(socket)

    if tab && pane_id && tab.layout do
      tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab.id, do: %{t | layout: Layout.maximize(t.layout, pane_id)}, else: t
        end)

      socket =
        socket
        |> assign(:tabs, tabs)
        |> persist_layout()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore_panes", _params, socket) do
    tab = active_tab(socket)

    if tab && tab.layout do
      tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab.id, do: %{t | layout: Layout.restore(t.layout)}, else: t
        end)

      socket =
        socket
        |> assign(:tabs, tabs)
        |> persist_layout()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore_crash_session", params, socket) do
    reconnect =
      case params["reconnect"] do
        true -> true
        "true" -> true
        _ -> false
      end

    case socket.assigns[:crash_recovery] do
      %{tabs: _tabs} = recovery ->
        socket =
          socket
          |> assign(:crash_recovery, nil)
          |> restore_saved_tabs(recovery, reconnect: reconnect)
          |> persist_layout()

        {:noreply, socket}

      _ ->
        {:noreply, assign(socket, :crash_recovery, nil)}
    end
  end

  def handle_event("dismiss_crash_recovery", _params, socket) do
    _ = Store.delete(:sessions, "host_live")
    {:noreply, assign(socket, :crash_recovery, nil)}
  end

  def handle_event("toggle_command_palette", _params, socket) do
    open? = !socket.assigns[:command_palette_open]

    {:noreply,
     socket
     |> assign(:command_palette_open, open?)
     |> assign(:command_palette_query, "")
     |> assign(:command_palette_index, 0)}
  end

  def handle_event("close_command_palette", _params, socket) do
    {:noreply,
     assign(socket,
       command_palette_open: false,
       command_palette_query: "",
       command_palette_index: 0
     )}
  end

  def handle_event("command_palette_search", %{"query" => query}, socket) do
    {:noreply, assign(socket, command_palette_query: query, command_palette_index: 0)}
  end

  def handle_event("command_palette_move", %{"dir" => dir}, socket) do
    items = palette_items(socket)
    idx = socket.assigns[:command_palette_index] || 0
    max_idx = max(length(items) - 1, 0)

    next =
      case dir do
        "up" -> max(idx - 1, 0)
        _ -> min(idx + 1, max_idx)
      end

    {:noreply, assign(socket, :command_palette_index, next)}
  end

  def handle_event("run_palette_command", params, socket) do
    items = palette_items(socket)
    idx = socket.assigns[:command_palette_index] || 0

    cmd =
      cond do
        is_binary(params["id"]) -> Enum.find(items, &(&1.id == params["id"]))
        true -> Enum.at(items, idx)
      end

    socket =
      assign(socket,
        command_palette_open: false,
        command_palette_query: "",
        command_palette_index: 0
      )

    dispatch_palette_command(socket, cmd)
  end

  def handle_event("handle_key", %{"key" => key, "ctrlKey" => true, "shiftKey" => true}, socket) do
    cond do
      key in ["\\", "|"] ->
        handle_event("split_right", %{}, socket)

      key in ["-", "_"] ->
        handle_event("split_down", %{}, socket)

      String.downcase(key) == "w" ->
        handle_event("close_pane", %{}, socket)

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("handle_key", %{"key" => key, "ctrlKey" => true, "altKey" => true}, socket) do
    if String.starts_with?(key, "Arrow") do
      handle_event("focus_next_pane", %{}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("handle_key", %{"key" => key} = params, socket) do
    ctrl? = params["ctrlKey"] == true or params["metaKey"] == true

    cond do
      ctrl? and String.downcase(to_string(key)) == "k" ->
        handle_event("toggle_command_palette", %{}, socket)

      socket.assigns[:command_palette_open] && key == "Escape" ->
        handle_event("close_command_palette", %{}, socket)

      socket.assigns[:command_palette_open] && key == "ArrowDown" ->
        handle_event("command_palette_move", %{"dir" => "down"}, socket)

      socket.assigns[:command_palette_open] && key == "ArrowUp" ->
        handle_event("command_palette_move", %{"dir" => "up"}, socket)

      socket.assigns[:command_palette_open] && key == "Enter" ->
        handle_event("run_palette_command", %{}, socket)

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("handle_key", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Info
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_servers(socket)}
  end

  def handle_info({:pty_output, session_id, data}, socket) do
    socket =
      socket
      |> push_event("terminal_output:#{session_id}", %{session_id: session_id, data: data})
      |> push_event("terminal_output_#{session_id}", %{data: data})

    {:noreply, socket}
  end

  def handle_info({:session_status, session_id, status}, socket) do
    msg =
      case status do
        :connected -> "\r\n\x1b[1;32m[ssh-client]\x1b[0m connected\r\n"
        :connecting -> "\r\n\x1b[1;34m[ssh-client]\x1b[0m connecting...\r\n"
        :reconnecting -> "\r\n\x1b[1;33m[ssh-client]\x1b[0m reconnecting...\r\n"
        :disconnected -> "\r\n\x1b[2m[ssh-client] disconnected\x1b[0m\r\n"
        :error -> "\r\n\x1b[1;31m[ssh-client]\x1b[0m connection error\r\n"
        _ -> nil
      end

    socket =
      if is_binary(msg) do
        push_event(socket, "terminal_output:#{session_id}", %{session_id: session_id, data: msg})
      else
        socket
      end

    {:noreply,
     assign(socket, :error, if(status == :error, do: socket.assigns[:error], else: nil))}
  end

  def handle_info({:session_error, session_id, reason}, socket) do
    err = format_session_error(reason)
    msg = "\r\n\x1b[1;31m[SSH Error]\x1b[0m #{err}\r\n"

    {:noreply,
     socket
     |> assign(:error, err)
     |> push_event("terminal_output:#{session_id}", %{session_id: session_id, data: msg})}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp send_pane_input(socket, params) do
    data = params["data"]
    pane_id = params["pane_id"] || socket.assigns.active_pane_id

    if is_binary(data) and pane_id do
      case SessionManager.get_session(pane_id) do
        {:ok, pid} when is_pid(pid) ->
          SessionWorker.send_input(pid, data)

        _ ->
          :ok
      end
    end

    {:noreply, socket}
  end

  defp resize_pane(socket, params) do
    pane_id = params["pane_id"] || socket.assigns.active_pane_id
    cols = parse_int(params["cols"])
    rows = parse_int(params["rows"])

    socket =
      if is_integer(cols) and is_integer(rows) do
        assign(socket, cols: cols, rows: rows)
      else
        socket
      end

    if (pane_id && is_integer(cols)) and is_integer(rows) do
      case SessionManager.get_session(pane_id) do
        {:ok, pid} when is_pid(pid) ->
          SessionWorker.resize(pid, cols, rows)

        _ ->
          :ok
      end
    end

    {:noreply, socket}
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp palette_items(socket) do
    CommandPalette.items(
      socket.assigns[:servers] || [],
      socket.assigns[:command_palette_query] || ""
    )
  end

  defp dispatch_palette_command(socket, nil), do: {:noreply, socket}

  defp dispatch_palette_command(socket, %{path: path}) when is_binary(path) do
    {:noreply, push_navigate(socket, to: path)}
  end

  defp dispatch_palette_command(socket, %{event: event}) when is_binary(event) do
    handle_event(event, %{}, socket)
  end

  defp dispatch_palette_command(socket, _), do: {:noreply, socket}

  defp format_session_error({:connection_failed, reason}),
    do: "Connection failed: #{format_session_error(reason)}"

  defp format_session_error(:econnrefused), do: "Connection refused — check host and port"
  defp format_session_error(:etimedout), do: "Connection timed out"
  defp format_session_error(:nxdomain), do: "Host name could not be resolved"
  defp format_session_error(:auth_failed), do: "Authentication failed"
  defp format_session_error(reason) when is_binary(reason), do: reason
  defp format_session_error(reason), do: inspect(reason)

  defp do_split(socket, direction, params) do
    case active_tab(socket) do
      nil ->
        {:noreply, socket}

      tab ->
        server = tab.server || find_server(socket, tab.server_id)

        if server do
          auto_connect = Map.get(params, "auto_connect", true)
          opts = [auto_connect: auto_connect]

          case SessionManager.create_session(server, opts) do
            {:ok, new_session_id} ->
              subscribe_session(new_session_id)
              target_pane = socket.assigns.active_pane_id || Layout.active_pane(tab.layout)
              new_layout = Layout.split(tab.layout, target_pane, direction, new_session_id)
              updated_tab = %{tab | layout: new_layout}

              tabs =
                Enum.map(socket.assigns.tabs, fn t ->
                  if t.id == tab.id, do: updated_tab, else: t
                end)

              socket =
                socket
                |> assign(:tabs, tabs)
                |> assign(:active_pane_id, new_session_id)
                |> persist_layout()

              {:noreply, socket}

            {:error, reason} ->
              {:noreply, assign(socket, :error, "Failed to split pane: #{inspect(reason)}")}
          end
        else
          {:noreply, socket}
        end
    end
  end

  defp active_tab(socket) do
    active_id = socket.assigns[:active_tab_id]
    tabs = socket.assigns[:tabs] || []
    Enum.find(tabs, &(&1.id == active_id)) || List.first(tabs)
  end

  defp find_server(socket, server_id) do
    Enum.find(socket.assigns.servers, fn s ->
      s_id =
        cond do
          is_map(s) and Map.has_key?(s, :id) -> s.id
          is_map(s) and Map.has_key?(s, "id") -> s["id"]
          true -> nil
        end

      to_string(s_id) == to_string(server_id)
    end)
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp parse_id(id), do: id

  defp subscribe_session(session_id) when is_binary(session_id) do
    try do
      Phoenix.PubSub.subscribe(SSHClient.PubSub, "ssh_client:session:#{session_id}")
    rescue
      _ -> :ok
    end
  end

  defp unsubscribe_session(session_id) when is_binary(session_id) do
    try do
      Phoenix.PubSub.unsubscribe(SSHClient.PubSub, "ssh_client:session:#{session_id}")
    rescue
      _ -> :ok
    end
  end

  defp load_servers(socket) do
    servers =
      try do
        ServerManager.list_servers()
        |> Enum.map(&format_server/1)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    online_count =
      Enum.count(servers, &(&1.status in ["polling", "connected", "online", "healthy"]))

    avg_cpu =
      case servers do
        [] -> 0.0
        list -> Enum.sum(Enum.map(list, & &1.cpu_percent)) / length(list)
      end

    workspaces =
      try do
        Workspace.list()
      rescue
        _ -> []
      end

    forwards =
      try do
        Forwarding.list()
      rescue
        _ -> []
      end

    socket
    |> assign(:servers, servers)
    |> assign(:online_count, online_count)
    |> assign(:avg_cpu, avg_cpu)
    |> assign(:workspaces, workspaces)
    |> assign(:forwards, forwards)
  end

  defp format_server(server) when is_map(server) do
    status = normalize_status(server[:status])
    metrics = server[:metrics] || %{}

    cpu_val =
      get_in(metrics, [:cpu, :used_percent]) ||
        get_in(metrics, ["cpu", "used_percent"]) ||
        Map.get(metrics, :cpu_percent, Map.get(metrics, "cpu_percent", 0.0))

    ram_val =
      get_in(metrics, [:memory, :used_percent]) ||
        get_in(metrics, ["memory", "used_percent"]) ||
        Map.get(metrics, :ram_percent, Map.get(metrics, "ram_percent", 0.0))

    disk_val =
      get_in(metrics, [:disk, :used_percent]) ||
        get_in(metrics, ["disk", "used_percent"]) ||
        Map.get(metrics, :disk_percent, Map.get(metrics, "disk_percent", 0.0))

    load_1 =
      get_in(metrics, [:cpu, :load_1]) ||
        get_in(metrics, ["cpu", "load_1"]) ||
        0.0

    uptime_str = metrics[:uptime] || metrics["uptime"] || nil

    raw_users = server[:users] || []
    raw_user = server[:user]

    users =
      cond do
        is_list(raw_users) and raw_users != [] -> Enum.map(raw_users, &to_string/1)
        raw_user && to_string(raw_user) != "" -> [to_string(raw_user)]
        true -> []
      end

    primary_user =
      if raw_user && to_string(raw_user) != "", do: to_string(raw_user), else: List.first(users)

    auth_method = server[:default_auth_method] || server[:auth_method] || :key

    %{
      id: to_string(server[:id]),
      name: to_string(server[:name] || server[:id]),
      host: to_string(server[:host] || ""),
      user: primary_user,
      users: users,
      default_auth_method: auth_method,
      port: server[:port] || 22,
      status: status,
      last_error: server[:last_error],
      cpu_percent: to_float(cpu_val),
      ram_percent: to_float(ram_val),
      disk_percent: to_float(disk_val),
      load_1: to_float(load_1),
      uptime: uptime_str,
      favorite: server[:favorite] == true,
      tags: server[:tags] || [],
      last_connected_at: server[:last_connected_at]
    }
  end

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(_), do: 0.0

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(_), do: "unknown"

  defp format_pct(v), do: "#{:erlang.float_to_binary(v, decimals: 1)}%"

  defp bar_color(v) when v >= 90, do: "bg-destructive"
  defp bar_color(v) when v >= 70, do: "bg-warning"
  defp bar_color(_), do: "bg-emerald-500"

  defp metric_color(v) when v >= 90, do: "text-destructive"
  defp metric_color(v) when v >= 70, do: "text-warning"
  defp metric_color(_), do: "text-muted-foreground"

  @doc "Fuzzy-filters and ranks servers by query string."
  def filter_servers(servers, query) do
    case String.trim(to_string(query)) do
      "" ->
        servers

      q ->
        q_down = String.downcase(q)

        servers
        |> Enum.map(fn s -> {s, fuzzy_score(s, q_down)} end)
        |> Enum.filter(fn {_s, score} -> score > 0 end)
        |> Enum.sort_by(fn {_s, score} -> score end, :desc)
        |> Enum.map(fn {s, _} -> s end)
    end
  end

  @doc "Computes fuzzy match score for a server against a query."
  def fuzzy_score(server, query) when is_binary(query) do
    fields =
      [server[:name], server[:host], server[:id]]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.downcase/1)

    target = Enum.join(fields, " ")

    cond do
      query in fields or target == query -> 1000
      String.starts_with?(target, query) -> 500
      String.contains?(target, query) -> 300
      true -> 0
    end
  end

  defp persist_layout(socket) do
    tabs = socket.assigns.tabs

    if tabs == [] do
      _ = Store.delete(:sessions, "host_live")
    else
      payload = %{
        "id" => "host_live",
        "active_tab_id" => socket.assigns[:active_tab_id],
        "active_pane_id" => socket.assigns[:active_pane_id],
        "workspace_id" => socket.assigns[:active_workspace_id],
        "tabs" =>
          Enum.map(tabs, fn t ->
            layout = t.layout

            %{
              "id" => t.id,
              "title" => t.title,
              "server_id" => t.server_id,
              "layout_type" => to_string((layout && layout.type) || :single),
              "pane_ids" => (layout && layout.panes) || [],
              "pane_count" => length((layout && layout.panes) || []),
              "active_pane" => layout && layout.active_pane,
              "maximized" => layout && layout.maximized
            }
          end),
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      _ = Store.put(:sessions, "host_live", payload)
    end

    socket
  rescue
    _ -> socket
  end

  defp check_crash_recovery(socket) do
    case Store.get(:sessions, "host_live") do
      %{"tabs" => saved_tabs} = saved when is_list(saved_tabs) and saved_tabs != [] ->
        all_live? =
          Enum.all?(saved_tabs, fn t ->
            panes = t["pane_ids"] || []
            panes != [] and Enum.all?(panes, &SessionManager.has_session?/1)
          end)

        if all_live? do
          restore_saved_tabs(socket, saved, reconnect: false, live: true)
        else
          ws_name =
            if ws_id = saved["workspace_id"] do
              case Workspace.get(ws_id) do
                %{"name" => name} -> name
                _ -> nil
              end
            end

          assign(socket, :crash_recovery, %{
            tabs: saved_tabs,
            count: length(saved_tabs),
            workspace_id: saved["workspace_id"],
            workspace_name: ws_name,
            updated_at: saved["updated_at"]
          })
        end

      _ ->
        socket
    end
  rescue
    _ -> socket
  end

  defp restore_saved_tabs(socket, saved, opts) when is_map(saved) do
    saved_tabs = saved[:tabs] || saved["tabs"] || []
    workspace_id = saved[:workspace_id] || saved["workspace_id"]
    active_tab_id = saved[:active_tab_id] || saved["active_tab_id"]

    live? = Keyword.get(opts, :live, false)
    reconnect? = Keyword.get(opts, :reconnect, false)
    auto_connect = if live?, do: false, else: reconnect?

    {new_tabs, _next_id} =
      Enum.reduce(saved_tabs, {[], 1}, fn tab_info, {tabs_acc, current_tab_id} ->
        server_id = tab_info[:server_id] || tab_info["server_id"]
        server = find_server(socket, server_id)

        if is_nil(server) do
          {tabs_acc, current_tab_id}
        else
          layout_type = parse_layout_type(tab_info[:layout_type] || tab_info["layout_type"])
          pane_ids = tab_info[:pane_ids] || tab_info["pane_ids"] || []
          pane_count = max(tab_info[:pane_count] || tab_info["pane_count"] || length(pane_ids), 1)

          layout =
            if live? do
              Enum.each(pane_ids, &subscribe_session/1)

              %Layout{
                type: layout_type,
                panes: pane_ids,
                active_pane:
                  tab_info[:active_pane] || tab_info["active_pane"] || List.first(pane_ids),
                maximized: tab_info[:maximized] || tab_info["maximized"]
              }
            else
              case SessionManager.create_session(server, auto_connect: auto_connect) do
                {:ok, first_session_id} ->
                  subscribe_session(first_session_id)
                  base_layout = Layout.new(first_session_id)

                  if pane_count > 1 do
                    dir =
                      if layout_type in [:split_v, "split_v"], do: :vertical, else: :horizontal

                    Enum.reduce(2..pane_count, base_layout, fn _idx, lay ->
                      case SessionManager.create_session(server, auto_connect: auto_connect) do
                        {:ok, next_id} ->
                          subscribe_session(next_id)
                          Layout.split(lay, Layout.active_pane(lay), dir, next_id)

                        _ ->
                          lay
                      end
                    end)
                  else
                    base_layout
                  end

                _ ->
                  nil
              end
            end

          if layout do
            title = tab_info[:title] || tab_info["title"] || server_title(server, server_id)

            tab = %{
              id: current_tab_id,
              title: title,
              server_id: server_id,
              server: server,
              layout: layout
            }

            {tabs_acc ++ [tab], current_tab_id + 1}
          else
            {tabs_acc, current_tab_id}
          end
        end
      end)

    if new_tabs == [] do
      socket
    else
      first = hd(new_tabs)
      active_tab = Enum.find(new_tabs, &(&1.id == active_tab_id)) || first

      socket
      |> assign(:tabs, new_tabs)
      |> assign(:active_tab_id, active_tab.id)
      |> assign(:active_pane_id, Layout.active_pane(active_tab.layout))
      |> assign(:next_tab_id, length(new_tabs) + 1)
      |> assign(:active_workspace_id, workspace_id)
    end
  end

  defp parse_layout_type("split_h"), do: :split_h
  defp parse_layout_type("split_v"), do: :split_v
  defp parse_layout_type("grid"), do: :grid
  defp parse_layout_type(:split_h), do: :split_h
  defp parse_layout_type(:split_v), do: :split_v
  defp parse_layout_type(:grid), do: :grid
  defp parse_layout_type(_), do: :single

  defp server_title(server, fallback) do
    cond do
      is_map(server) and Map.has_key?(server, :name) and not is_nil(server.name) ->
        server.name

      is_map(server) and Map.has_key?(server, "name") and not is_nil(server["name"]) ->
        server["name"]

      is_map(server) and Map.has_key?(server, :id) and not is_nil(server.id) ->
        server.id

      is_map(server) and Map.has_key?(server, "id") and not is_nil(server["id"]) ->
        server["id"]

      true ->
        fallback
    end
  end
end
