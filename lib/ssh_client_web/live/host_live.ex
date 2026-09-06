defmodule SSHClientWeb.HostLive do
  @moduledoc """
  Main host list LiveView — shows all registered SSH servers with live status,
  CPU/RAM/disk metrics, and one-click terminal launch.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}

  alias SSHClient.Keychain
  alias SSHClient.ServerManager
  alias SSHClient.ServerWorker
  alias SSHClient.Vault

  @refresh_interval 5_000

  alias SSHClient.Updater

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
        |> assign(:error, nil)
        |> load_servers()

      {:ok, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Events
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
            match?({:ok, secret} when is_binary(secret) and secret != "", Keychain.retrieve("#{primary_user}@#{server.id}"))
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
      if server && user != "" and user != "custom" do
        match?({:ok, secret} when is_binary(secret) and secret != "", Keychain.retrieve("#{user}@#{server.id}"))
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
    auth_method = if (params["auth_method"] || socket.assigns[:new_auth_method]) in ["password", :password], do: "password", else: "key"
    password = params["password"] || socket.assigns[:new_password] || ""
    remember = params["remember_password"] in ["true", true, "on"] or socket.assigns[:new_remember_password] == true

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

  def handle_event("lock_vault", _params, socket) do
    Vault.lock()
    {:noreply, push_navigate(socket, to: "/lock")}
  end

  # ---------------------------------------------------------------------------
  # Info
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_servers(socket)}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    filtered = filter_servers(assigns.servers, assigns.filter)
    assigns = assign(assigns, :filtered_servers, filtered)

    ~H"""
    <div class="flex h-full min-h-screen bg-[#050505]">
      <!-- Sidebar -->
      <aside class="w-56 bg-[#0a0a0a] border-r border-[#1f1f1f] flex flex-col shrink-0">
        <div class="px-5 py-4 border-b border-[#1f1f1f] flex items-center justify-between">
          <div class="flex items-center gap-3">
            <img src="/images/icon.png" alt="Logo" class="w-7 h-7 rounded-lg" />
            <div>
              <span class="text-white font-semibold text-sm tracking-tight block">ssh-client</span>
              <span class="block text-[10px] text-zinc-600 font-mono">v<%= @version %></span>
            </div>
          </div>
          <span class="px-1.5 py-0.5 text-[9px] font-mono font-semibold uppercase tracking-wider rounded bg-red-500/10 text-red-400 border border-red-500/20">BETA</span>
        </div>
        <nav class="flex-1 px-3 py-4 space-y-0.5">
          <a
            href="/"
            class="flex items-center gap-2.5 px-3 py-2 rounded-lg bg-blue-600/10 text-blue-400 text-sm font-medium"
          >
            Hosts
          </a>
          <a
            href="/logs"
            class="flex items-center gap-2.5 px-3 py-2 rounded-lg text-zinc-500 hover:text-zinc-300 hover:bg-white/5 text-sm font-medium transition-colors"
          >
            Logs
          </a>
          <a
            href="/settings"
            class="flex items-center gap-2.5 px-3 py-2 rounded-lg text-zinc-500 hover:text-zinc-300 hover:bg-white/5 text-sm font-medium transition-colors"
          >
            Settings
          </a>
        </nav>
        <div class="px-5 py-4 border-t border-[#1f1f1f] flex items-center justify-between">
          <span class="text-[11px] text-zinc-700">
            <%= length(@servers) %> host<%= if length(@servers) != 1, do: "s" %>
          </span>
          <div class="flex items-center gap-2.5">
            <button
              phx-click="lock_vault"
              class="text-[10px] text-zinc-600 hover:text-zinc-400 font-mono transition-colors"
              title="Lock Vault"
            >
              Lock
            </button>
            <a
              href="/settings"
              class="text-[10px] text-blue-500 hover:text-blue-400 font-mono transition-colors"
            >
              Update
            </a>
          </div>
        </div>
      </aside>

      <!-- Main content -->
      <div class="flex-1 flex flex-col min-w-0">
        <!-- Topbar -->
        <header class="h-14 flex items-center justify-between px-6 border-b border-[#1f1f1f] bg-[#050505] shrink-0">
          <div class="flex items-center gap-3">
            <h1 class="text-sm font-semibold text-white tracking-tight">Hosts</h1>
            <span class="text-[11px] text-zinc-600 font-mono"><%= length(@filtered_servers) %> shown</span>
          </div>
          <div class="flex items-center gap-2">
            <input
              type="text"
              value={@filter}
              placeholder="Search hosts..."
              phx-keyup="search"
              phx-value-value={@filter}
              class="h-8 px-3 bg-[#111] border border-[#1f1f1f] rounded-lg text-sm text-zinc-300 placeholder-zinc-600 focus:outline-none focus:border-blue-500/60 w-48 font-mono"
            />
            <button
              phx-click="poll_all"
              class="h-8 px-3 bg-[#111] border border-[#1f1f1f] hover:border-zinc-600 text-zinc-400 text-sm rounded-lg transition-colors"
            >
              Refresh
            </button>
            <button
              phx-click="open_add_modal"
              class="h-8 px-4 bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium rounded-lg transition-colors"
            >
              + Add Host
            </button>
          </div>
        </header>

        <!-- Host table -->
        <div class="flex-1 overflow-auto">
          <%= if @filtered_servers == [] do %>
            <div class="flex flex-col items-center justify-center h-64 gap-3">
              <span class="text-zinc-600 text-sm">No hosts found</span>
              <button phx-click="open_add_modal" class="text-blue-500 hover:text-blue-400 text-sm transition-colors">
                Add your first host
              </button>
            </div>
          <% else %>
            <table class="w-full text-left border-collapse text-sm">
              <thead>
                <tr class="border-b border-[#1f1f1f]">
                  <th class="px-6 py-3 text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Name</th>
                  <th class="px-6 py-3 text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Address</th>
                  <th class="px-6 py-3 text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Status</th>
                  <th class="px-6 py-3 text-[11px] font-medium text-zinc-600 uppercase tracking-wider">CPU</th>
                  <th class="px-6 py-3 text-[11px] font-medium text-zinc-600 uppercase tracking-wider">RAM</th>
                  <th class="px-6 py-3 text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Disk</th>
                  <th class="px-6 py-3 text-[11px] font-medium text-zinc-600 uppercase tracking-wider text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for server <- @filtered_servers do %>
                  <tr class="border-b border-[#0f0f0f] hover:bg-white/[0.015] group transition-colors">
                    <td class="px-6 py-3.5 font-medium text-white">
                      <%= server.name %>
                    </td>
                    <td class="px-6 py-3.5 font-mono text-[13px]">
                      <div class="text-zinc-300"><%= server.host %></div>
                      <div class="text-[11px] text-zinc-500 flex items-center gap-1.5 mt-0.5">
                        <span><%= server.user %></span>
                        <%= if length(server.users || []) > 1 do %>
                          <button
                            type="button"
                            phx-click="open_connect_modal"
                            phx-value-id={server.id}
                            class="text-[10px] px-1.5 py-0.5 bg-[#18181b] hover:bg-[#27272a] text-zinc-400 hover:text-zinc-200 border border-[#27272a] rounded transition-colors"
                            title="Multiple accounts configured - click to select"
                          >
                            +<%= length(server.users) - 1 %> users
                          </button>
                        <% end %>
                        <%= if server.default_auth_method == :password do %>
                          <span class="text-[10px] px-1 py-0.2 bg-amber-500/10 text-amber-400 border border-amber-500/20 rounded font-mono" title="Password Authentication">
                            pwd
                          </span>
                        <% end %>
                      </div>
                    </td>
                    <td class="px-6 py-3.5">
                      <div class="flex items-center gap-1.5">
                        <span class={["inline-flex items-center px-2 py-0.5 rounded text-[11px] font-medium font-mono tracking-wide", badge_class(server.status)]}>
                          <%= server.status %>
                        </span>
                        <%= if server.last_error do %>
                          <a
                            href="/logs"
                            title={inspect(server.last_error)}
                            class="w-2 h-2 rounded-full bg-red-400 hover:bg-red-300 animate-pulse cursor-pointer"
                          ></a>
                        <% end %>
                      </div>
                    </td>
                    <td class="px-6 py-3.5">
                      <div class="flex items-center gap-2">
                        <div class="w-14 h-1.5 bg-[#18181b] rounded-full overflow-hidden shrink-0">
                          <div class={["h-full rounded-full transition-all duration-300", bar_color(server.cpu_percent)]} style={"width: #{min(100.0, max(0.0, server.cpu_percent))}%"}></div>
                        </div>
                        <span class={["text-[12px] font-mono font-medium", metric_color(server.cpu_percent)]}>
                          <%= format_pct(server.cpu_percent) %>
                        </span>
                      </div>
                    </td>
                    <td class="px-6 py-3.5">
                      <div class="flex items-center gap-2">
                        <div class="w-14 h-1.5 bg-[#18181b] rounded-full overflow-hidden shrink-0">
                          <div class={["h-full rounded-full transition-all duration-300", bar_color(server.ram_percent)]} style={"width: #{min(100.0, max(0.0, server.ram_percent))}%"}></div>
                        </div>
                        <span class={["text-[12px] font-mono font-medium", metric_color(server.ram_percent)]}>
                          <%= format_pct(server.ram_percent) %>
                        </span>
                      </div>
                    </td>
                    <td class="px-6 py-3.5">
                      <div class="flex items-center gap-2">
                        <div class="w-14 h-1.5 bg-[#18181b] rounded-full overflow-hidden shrink-0">
                          <div class={["h-full rounded-full transition-all duration-300", bar_color(server.disk_percent)]} style={"width: #{min(100.0, max(0.0, server.disk_percent))}%"}></div>
                        </div>
                        <span class={["text-[12px] font-mono font-medium", metric_color(server.disk_percent)]}>
                          <%= format_pct(server.disk_percent) %>
                        </span>
                      </div>
                    </td>
                    <td class="px-6 py-3.5 text-right">
                      <div class="flex items-center justify-end gap-1.5">
                        <button
                          phx-click="open_connect_modal"
                          phx-value-id={server.id}
                          class="px-2.5 py-1 bg-blue-600 hover:bg-blue-500 text-white text-xs font-mono font-medium rounded-md transition-colors shadow-sm"
                          title="Connect (Select account and auth method)"
                        >
                          Connect
                        </button>
                        <a
                          href={"/sftp/#{server.id}"}
                          class="px-2.5 py-1 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-300 hover:text-white text-xs font-mono rounded-md transition-colors inline-flex items-center"
                          title="Open SFTP File Explorer"
                        >
                          SFTP
                        </a>
                        <button
                          phx-click="poll_now"
                          phx-value-id={server.id}
                          class="px-2 py-1 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-400 hover:text-white text-xs font-mono rounded-md transition-colors"
                          title="Refresh Server Metrics"
                        >
                          Refresh
                        </button>
                        <button
                          phx-click="remove_server"
                          phx-value-id={server.id}
                          data-confirm={"Are you sure you want to remove #{server.name}?"}
                          class="px-2 py-1 bg-red-500/10 border border-red-500/20 hover:bg-red-500/20 text-red-400 hover:text-red-300 text-xs font-mono rounded-md transition-colors"
                          title="Delete Host Configuration"
                        >
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>
    </div>

    <!-- Add Host Modal -->
    <%= if @add_modal do %>
      <div class="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-center justify-center z-50">
        <div class="bg-[#0a0a0a] border border-[#1f1f1f] rounded-2xl w-full max-w-md p-6 shadow-2xl">
          <div class="flex items-center justify-between mb-5">
            <h2 class="text-sm font-semibold text-white">Add SSH Host</h2>
            <button phx-click="close_add_modal" class="text-zinc-600 hover:text-zinc-400 transition-colors text-lg leading-none">&times;</button>
          </div>

          <%= if @error do %>
            <div class="mb-4 px-3 py-2 bg-red-500/10 border border-red-500/20 rounded-lg text-red-400 text-xs font-mono">
              <%= @error %>
            </div>
          <% end %>

          <form phx-change="form_change" phx-submit="add_server" autocomplete="off" class="space-y-3">
            <div>
              <label class="block text-[11px] text-zinc-600 uppercase tracking-wider mb-1.5">Name</label>
              <input
                type="text"
                name="name"
                value={@new_name}
                phx-debounce="200"
                placeholder="Production Web"
                autocomplete="off"
                autocorrect="off"
                autocapitalize="off"
                spellcheck="false"
                class="w-full h-9 px-3 bg-[#111] border border-[#1f1f1f] focus:border-blue-500/60 rounded-lg text-sm text-zinc-300 placeholder-zinc-700 focus:outline-none"
              />
            </div>
            <div>
              <label class="block text-[11px] text-zinc-600 uppercase tracking-wider mb-1.5">Host / IP</label>
              <input
                type="text"
                name="host"
                value={@new_host}
                phx-debounce="200"
                placeholder="192.168.1.10"
                autocomplete="off"
                autocorrect="off"
                autocapitalize="off"
                spellcheck="false"
                class="w-full h-9 px-3 bg-[#111] border border-[#1f1f1f] focus:border-blue-500/60 rounded-lg text-sm text-zinc-300 placeholder-zinc-700 focus:outline-none font-mono"
              />
            </div>
            <div class="flex gap-3">
              <div class="flex-1">
                <label class="block text-[11px] text-zinc-600 uppercase tracking-wider mb-1.5">User</label>
                <input
                  type="text"
                  name="user"
                  value={@new_user}
                  phx-debounce="200"
                  placeholder="ubuntu"
                  autocomplete="off"
                  autocorrect="off"
                  autocapitalize="off"
                  spellcheck="false"
                  class="w-full h-9 px-3 bg-[#111] border border-[#1f1f1f] focus:border-blue-500/60 rounded-lg text-sm text-zinc-300 placeholder-zinc-700 focus:outline-none font-mono"
                />
              </div>
              <div class="w-24">
                <label class="block text-[11px] text-zinc-600 uppercase tracking-wider mb-1.5">Port</label>
                <input
                  type="number"
                  name="port"
                  value={@new_port}
                  phx-debounce="200"
                  placeholder="22"
                  autocomplete="off"
                  class="w-full h-9 px-3 bg-[#111] border border-[#1f1f1f] focus:border-blue-500/60 rounded-lg text-sm text-zinc-300 placeholder-zinc-700 focus:outline-none font-mono"
                />
              </div>
            </div>
            <div>
              <label class="block text-[11px] text-zinc-600 uppercase tracking-wider mb-1.5">Additional Users (optional, comma-separated)</label>
              <input
                type="text"
                name="users"
                value={@new_users}
                phx-debounce="200"
                placeholder="root, deploy, developer"
                autocomplete="off"
                autocorrect="off"
                autocapitalize="off"
                spellcheck="false"
                class="w-full h-9 px-3 bg-[#111] border border-[#1f1f1f] focus:border-blue-500/60 rounded-lg text-sm text-zinc-300 placeholder-zinc-700 focus:outline-none font-mono"
              />
            </div>
            <div>
              <label class="block text-[11px] text-zinc-600 uppercase tracking-wider mb-1.5">Default Authentication</label>
              <select
                name="auth_method"
                class="w-full h-9 px-3 bg-[#111] border border-[#1f1f1f] focus:border-blue-500/60 rounded-lg text-sm text-zinc-300 focus:outline-none font-mono"
              >
                <option value="key" selected={@new_auth_method == "key"}>SSH Key</option>
                <option value="password" selected={@new_auth_method == "password"}>Password</option>
              </select>
            </div>
            <div>
              <label class="block text-[11px] text-zinc-600 uppercase tracking-wider mb-1.5">
                Password <%= if @new_auth_method == "password", do: "(required for password auth)", else: "(optional, saved to Keychain)" %>
              </label>
              <input
                type="password"
                name="password"
                value={@new_password}
                phx-debounce="200"
                placeholder="Enter server password"
                autocomplete="new-password"
                class="w-full h-9 px-3 bg-[#111] border border-[#1f1f1f] focus:border-blue-500/60 rounded-lg text-sm text-zinc-300 placeholder-zinc-700 focus:outline-none font-mono"
              />
            </div>
            <div class="flex items-center gap-2 pt-0.5">
              <input
                type="checkbox"
                id="add_remember_password"
                name="remember_password"
                value="true"
                checked={@new_remember_password}
                class="checkbox checkbox-xs checkbox-primary rounded"
              />
              <label for="add_remember_password" class="text-xs text-zinc-400 select-none cursor-pointer">
                Save password in OS Keychain
              </label>
            </div>
            <div class="flex gap-2 pt-1">
              <button
                type="button"
                phx-click="close_add_modal"
                class="flex-1 h-9 border border-[#1f1f1f] hover:border-zinc-600 text-zinc-400 text-sm rounded-lg transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="flex-1 h-9 bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium rounded-lg transition-colors"
              >
                Add Host
              </button>
            </div>
          </form>
        </div>
      </div>
    <% end %>

    <!-- Connect Modal (Multi-User & Password Auth) -->
    <%= if @connect_modal and @connect_server do %>
      <div class="fixed inset-0 bg-black/75 backdrop-blur-sm flex items-center justify-center z-50">
        <div class="bg-[#0a0a0a] border border-[#1f1f1f] rounded-2xl w-full max-w-md p-6 shadow-2xl">
          <div class="flex items-center justify-between mb-4">
            <div>
              <h2 class="text-sm font-semibold text-white">Connect to <%= @connect_server.name %></h2>
              <p class="text-[11px] text-zinc-500 font-mono mt-0.5"><%= @connect_server.host %>:<%= @connect_server.port %></p>
            </div>
            <button phx-click="close_connect_modal" class="text-zinc-600 hover:text-zinc-400 transition-colors text-lg leading-none">&times;</button>
          </div>

          <form phx-submit="submit_connect" class="space-y-4">
            <!-- Target User Selection -->
            <div>
              <label class="block text-[11px] text-zinc-500 uppercase tracking-wider mb-2 font-mono">User Account</label>
              <div class="flex flex-wrap gap-1.5 mb-2">
                <%= for u <- @connect_users do %>
                  <button
                    type="button"
                    phx-click="select_connect_user"
                    phx-value-user={u}
                    class={["px-2.5 py-1 text-xs font-mono rounded-md border transition-colors",
                      if(@connect_user == u, do: "bg-blue-600/20 border-blue-500/50 text-blue-400 font-semibold", else: "bg-[#141414] border-[#222] text-zinc-400 hover:text-zinc-200 hover:border-zinc-700")]}
                  >
                    <%= u %>
                  </button>
                <% end %>
                <button
                  type="button"
                  phx-click="select_connect_user"
                  phx-value-user="custom"
                  class={["px-2.5 py-1 text-xs font-mono rounded-md border transition-colors",
                    if(@connect_user == "custom", do: "bg-blue-600/20 border-blue-500/50 text-blue-400 font-semibold", else: "bg-[#141414] border-[#222] text-zinc-400 hover:text-zinc-200 hover:border-zinc-700")]}
                >
                  + Other
                </button>
              </div>

              <input type="hidden" name="user" value={@connect_user} />

              <%= if @connect_user == "custom" do %>
                <input
                  type="text"
                  name="custom_user"
                  placeholder="Enter username (e.g. deploy)"
                  required
                  class="w-full h-9 px-3 bg-[#111] border border-[#1f1f1f] focus:border-blue-500/60 rounded-lg text-sm text-zinc-300 placeholder-zinc-700 focus:outline-none font-mono"
                />
              <% end %>
            </div>

            <!-- Authentication Method Tabs -->
            <div>
              <label class="block text-[11px] text-zinc-500 uppercase tracking-wider mb-1.5 font-mono">Authentication</label>
              <div class="grid grid-cols-2 gap-2 p-1 bg-[#111] border border-[#1f1f1f] rounded-lg">
                <button
                  type="button"
                  phx-click="set_connect_auth_method"
                  phx-value-method="key"
                  class={["py-1 text-xs font-mono rounded transition-colors text-center",
                    if(@connect_auth_method == :key, do: "bg-[#1f1f1f] text-white font-medium", else: "text-zinc-500 hover:text-zinc-300")]}
                >
                  SSH Key
                </button>
                <button
                  type="button"
                  phx-click="set_connect_auth_method"
                  phx-value-method="password"
                  class={["py-1 text-xs font-mono rounded transition-colors text-center",
                    if(@connect_auth_method == :password, do: "bg-[#1f1f1f] text-white font-medium", else: "text-zinc-500 hover:text-zinc-300")]}
                >
                  Password
                </button>
              </div>
              <input type="hidden" name="auth_method" value={to_string(@connect_auth_method)} />
            </div>

            <!-- Password Input (if Password auth selected) -->
            <%= if @connect_auth_method == :password do %>
              <div class="space-y-2">
                <%= if @has_saved_password do %>
                  <div class="px-3 py-2 bg-emerald-500/10 border border-emerald-500/20 rounded-lg text-emerald-400 text-xs font-mono flex items-center justify-between">
                    <span>Saved password available in Credential Manager</span>
                  </div>
                <% end %>

                <div>
                  <label class="block text-[11px] text-zinc-500 uppercase tracking-wider mb-1 font-mono">
                    <%= if @has_saved_password, do: "Override Password (optional)", else: "Server Password" %>
                  </label>
                  <input
                    type="password"
                    name="password"
                    value={@connect_password}
                    placeholder={if @has_saved_password, do: "Leave empty to use saved password", else: "Enter server password"}
                    class="w-full h-9 px-3 bg-[#111] border border-[#1f1f1f] focus:border-blue-500/60 rounded-lg text-sm text-zinc-300 placeholder-zinc-700 focus:outline-none font-mono"
                  />
                </div>

                <div class="flex items-center gap-2 pt-0.5">
                  <input
                    type="checkbox"
                    id="remember_keychain"
                    name="remember"
                    value="true"
                    checked={@connect_remember}
                    class="rounded border-[#27272a] bg-[#111] text-blue-600 focus:ring-0 focus:ring-offset-0"
                  />
                  <label for="remember_keychain" class="text-xs text-zinc-400 select-none cursor-pointer">
                    Remember password in OS Keychain / Credential Manager
                  </label>
                </div>
              </div>
            <% end %>

            <!-- Submit Actions: Terminal vs SFTP -->
            <div class="flex gap-2 pt-2">
              <button
                type="submit"
                name="action"
                value="terminal"
                class="flex-1 h-9 bg-blue-600 hover:bg-blue-500 text-white rounded-lg text-xs font-mono font-medium transition-colors"
              >
                Launch Terminal
              </button>
              <button
                type="submit"
                name="action"
                value="sftp"
                class="px-4 h-9 bg-[#141414] hover:bg-[#1f1f1f] border border-[#27272a] hover:border-zinc-500 text-zinc-200 rounded-lg text-xs font-mono transition-colors"
              >
                Open SFTP
              </button>
              <button
                type="button"
                phx-click="close_connect_modal"
                class="px-3 h-9 bg-transparent hover:bg-white/5 text-zinc-500 hover:text-zinc-300 rounded-lg text-xs font-mono transition-colors"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>
      </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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

    assign(socket, :servers, servers)
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

    primary_user = if raw_user && to_string(raw_user) != "", do: to_string(raw_user), else: List.first(users)
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
      uptime: uptime_str
    }
  end

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(_), do: 0.0

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(_), do: "unknown"

  defp format_pct(v), do: "#{:erlang.float_to_binary(v, decimals: 1)}%"

  defp badge_class("polling"), do: "bg-emerald-500/10 text-emerald-400 border border-emerald-500/20"
  defp badge_class("connecting"), do: "bg-blue-500/10 text-blue-400 border border-blue-500/20"
  defp badge_class("degraded"), do: "bg-amber-500/10 text-amber-400 border border-amber-500/20"
  defp badge_class("reconnecting"), do: "bg-purple-500/10 text-purple-400 border border-purple-500/20"
  defp badge_class(_), do: "bg-zinc-800 text-zinc-500 border border-zinc-700/50"

  defp bar_color(v) when v >= 90, do: "bg-red-500"
  defp bar_color(v) when v >= 70, do: "bg-amber-500"
  defp bar_color(_), do: "bg-emerald-500"

  defp metric_color(v) when v >= 90, do: "text-red-400"
  defp metric_color(v) when v >= 70, do: "text-amber-400"
  defp metric_color(_), do: "text-zinc-400"

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
end
