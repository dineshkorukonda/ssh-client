defmodule SSHClientWeb.HostLive do
  @moduledoc """
  Main host list LiveView — shows all registered SSH servers with live status,
  CPU/RAM/disk metrics, and one-click terminal launch.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}
  import SSHClientWeb.CoreComponents

  alias SSHClient.Keychain
  alias SSHClient.ServerManager
  alias SSHClient.ServerWorker
  alias SSHClient.SSH.ConfigImporter
  alias SSHClient.Updater
  alias SSHClient.Vault

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
    online_count = Enum.count(assigns.servers, &(&1.status in ["polling", "connected"]))
    avg_cpu =
      case assigns.servers do
        [] -> 0.0
        list -> Enum.sum(Enum.map(list, & &1.cpu_percent)) / length(list)
      end

    assigns =
      assigns
      |> assign(:filtered_servers, filtered)
      |> assign(:online_count, online_count)
      |> assign(:avg_cpu, avg_cpu)

    ~H"""
    <div class="flex flex-col h-full min-h-screen bg-background text-foreground antialiased">
      <!-- Top Navigation Header -->
      <.top_navigation
        current_tab={:hosts}
        version={@version}
        servers_count={length(@servers)}
        online_count={@online_count}
      />

      <!-- Main Workspace Canvas -->
      <main class="flex-1 overflow-auto p-6 md:p-8 space-y-6 max-w-7xl w-full mx-auto">
        <!-- Sub-Header / Command Toolbar -->
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div>
            <h1 class="text-xl font-semibold text-foreground tracking-tight">Managed Infrastructure</h1>
            <p class="text-xs text-muted-foreground font-mono mt-0.5">
              <%= length(@filtered_servers) %> endpoints configured across clusters
            </p>
          </div>

          <div class="flex items-center gap-2.5 flex-wrap">
            <div class="relative">
              <input
                type="text"
                value={@filter}
                placeholder="Filter servers (name, IP)..."
                phx-keyup="search"
                phx-value-value={@filter}
                class="h-9 pl-3 pr-8 bg-card border border-border rounded-md text-xs text-foreground placeholder-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring w-48 sm:w-56 font-mono transition-colors shadow-sm"
              />
            </div>
            <button
              phx-click="scan_and_import_ssh_config"
              class="h-9 px-3 bg-secondary hover:bg-secondary/80 text-secondary-foreground border border-border text-xs font-mono font-medium rounded-md transition-colors shadow-sm inline-flex items-center gap-1.5"
              title="Scan and import hosts from ~/.ssh/config"
            >
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" />
              </svg>
              Import ~/.ssh/config
            </button>
            <button
              phx-click="poll_all"
              class="h-9 px-3 bg-secondary hover:bg-secondary/80 text-secondary-foreground border border-border text-xs font-mono font-medium rounded-md transition-colors shadow-sm"
              title="Poll all server metrics"
            >
              Poll All
            </button>
            <button
              phx-click="open_add_modal"
              class="h-9 px-3 bg-primary text-primary-foreground hover:bg-primary/90 text-xs font-mono font-semibold rounded-md transition-colors shadow-sm"
            >
              + Add Server
            </button>
          </div>
        </div>

        <!-- 4 Overview Stat Cards (Shadcn Style) -->
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <.stat_card
            title="Total Servers"
            value={length(@servers)}
            subtext="Configured SSH endpoints"
          />

          <.stat_card
            title="Online & Polling"
            value={"#{@online_count} / #{length(@servers)}"}
            subtext="Responding to healthchecks"
            accent={if(@online_count > 0, do: "text-emerald-500", else: "text-muted-foreground")}
          />

          <.stat_card
            title="Average CPU Load"
            value={format_pct(@avg_cpu)}
            subtext="Aggregate cluster compute"
          />

          <.stat_card
            title="Telemetry Status"
            value="Active"
            subtext="Interval: 5s background poll"
            accent="text-emerald-500"
          />
        </div>

        <!-- Server List Data Table -->
        <div class="shadcn-card overflow-hidden">
          <div class="px-6 py-4 border-b border-border bg-card/50 flex items-center justify-between">
            <div>
              <h2 class="text-sm font-semibold text-foreground font-mono uppercase tracking-wider">Server Endpoints</h2>
            </div>
            <span class="text-xs text-muted-foreground font-mono">Live Telemetry</span>
          </div>

          <%= if @filtered_servers == [] do %>
            <div class="flex flex-col items-center justify-center py-16 px-4 gap-3 text-center">
              <div class="w-12 h-12 rounded-xl bg-muted flex items-center justify-center text-muted-foreground mb-1">
                <svg class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01" />
                </svg>
              </div>
              <h3 class="text-sm font-semibold text-foreground">
                <%= if @servers == [], do: "No SSH Hosts Configured", else: "No matching endpoints found" %>
              </h3>
              <p class="text-xs text-muted-foreground font-mono max-w-sm">
                <%= if @servers == [] do %>
                  Add your remote servers manually or automatically import existing hosts from your local OpenSSH config file.
                <% else %>
                  Try refining your search filter above to locate the target server.
                <% end %>
              </p>
              <div class="flex items-center gap-2.5 pt-2">
                <button
                  phx-click="scan_and_import_ssh_config"
                  class="px-4 py-2 bg-secondary text-secondary-foreground hover:bg-secondary/80 border border-border text-xs font-mono font-medium rounded-md transition-colors inline-flex items-center gap-1.5"
                >
                  <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" />
                  </svg>
                  Import from ~/.ssh/config
                </button>
                <button
                  phx-click="open_add_modal"
                  class="px-4 py-2 bg-primary text-primary-foreground hover:bg-primary/90 text-xs font-mono font-semibold rounded-md transition-colors"
                >
                  + Add New Server
                </button>
              </div>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="w-full text-left font-mono text-xs">
                <thead>
                  <tr class="border-b border-border text-muted-foreground text-[11px] uppercase tracking-wider bg-muted/20">
                    <th class="py-3 px-5 font-medium">Server Name</th>
                    <th class="py-3 px-5 font-medium">Endpoint</th>
                    <th class="py-3 px-5 font-medium">Status</th>
                    <th class="py-3 px-5 font-medium">CPU</th>
                    <th class="py-3 px-5 font-medium">Memory</th>
                    <th class="py-3 px-5 font-medium">Disk</th>
                    <th class="py-3 px-5 font-medium text-right">Actions</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-border">
                  <%= for server <- @filtered_servers do %>
                    <tr class="hover:bg-muted/40 transition-colors">
                      <td class="py-3.5 px-5 font-semibold text-foreground">
                        <div class="flex items-center gap-2.5">
                          <span class={"status-dot " <> if(server.status in ["polling", "connected"], do: "online", else: "offline")}></span>
                          <span><%= server.name %></span>
                        </div>
                      </td>
                      <td class="py-3.5 px-5">
                        <div class="text-foreground font-mono"><%= server.host %>:<%= server.port %></div>
                        <div class="text-[11px] text-muted-foreground flex items-center gap-1.5 mt-0.5">
                          <span><%= server.user %></span>
                          <%= if length(server.users || []) > 1 do %>
                            <button
                              type="button"
                              phx-click="open_connect_modal"
                              phx-value-id={server.id}
                              class="text-[10px] px-1.5 py-0.2 bg-muted hover:bg-accent text-muted-foreground border border-border rounded transition-colors"
                            >
                              +<%= length(server.users) - 1 %>
                            </button>
                          <% end %>
                          <%= if server.default_auth_method == :password do %>
                            <span class="text-[10px] px-1 py-0.2 bg-muted text-muted-foreground border border-border rounded">
                              pwd
                            </span>
                          <% end %>
                        </div>
                      </td>
                      <td class="py-3.5 px-5">
                        <.status_badge status={server.status} />
                      </td>
                      <td class="py-3.5 px-5">
                        <div class="flex items-center gap-2">
                          <div class="w-16 h-1.5 bg-muted rounded-full overflow-hidden shrink-0">
                            <div class={["h-full rounded-full transition-all duration-300", bar_color(server.cpu_percent)]} style={"width: #{min(100.0, max(0.0, server.cpu_percent))}%"}></div>
                          </div>
                          <span class={["text-[11px] font-mono", metric_color(server.cpu_percent)]}>
                            <%= format_pct(server.cpu_percent) %>
                          </span>
                        </div>
                      </td>
                      <td class="py-3.5 px-5">
                        <div class="flex items-center gap-2">
                          <div class="w-16 h-1.5 bg-muted rounded-full overflow-hidden shrink-0">
                            <div class={["h-full rounded-full transition-all duration-300", bar_color(server.ram_percent)]} style={"width: #{min(100.0, max(0.0, server.ram_percent))}%"}></div>
                          </div>
                          <span class={["text-[11px] font-mono", metric_color(server.ram_percent)]}>
                            <%= format_pct(server.ram_percent) %>
                          </span>
                        </div>
                      </td>
                      <td class="py-3.5 px-5">
                        <div class="flex items-center gap-2">
                          <div class="w-16 h-1.5 bg-muted rounded-full overflow-hidden shrink-0">
                            <div class={["h-full rounded-full transition-all duration-300", bar_color(server.disk_percent)]} style={"width: #{min(100.0, max(0.0, server.disk_percent))}%"}></div>
                          </div>
                          <span class={["text-[11px] font-mono", metric_color(server.disk_percent)]}>
                            <%= format_pct(server.disk_percent) %>
                          </span>
                        </div>
                      </td>
                      <td class="py-3.5 px-5 text-right">
                        <div class="flex items-center justify-end gap-1.5">
                          <button
                            phx-click="open_connect_modal"
                            phx-value-id={server.id}
                            class="h-7 px-2.5 bg-primary text-primary-foreground hover:bg-primary/90 text-xs font-mono font-medium rounded transition-colors shadow-sm"
                            title="Connect terminal session"
                          >
                            Connect
                          </button>
                          <a
                            href={"/sftp/#{server.id}"}
                            class="h-7 px-2.5 flex items-center bg-secondary hover:bg-secondary/80 text-secondary-foreground border border-border text-xs font-mono rounded transition-colors"
                            title="Open SFTP Explorer"
                          >
                            SFTP
                          </a>
                          <button
                            phx-click="poll_now"
                            phx-value-id={server.id}
                            class="h-7 px-2 bg-transparent hover:bg-muted text-muted-foreground hover:text-foreground text-xs font-mono rounded transition-colors"
                            title="Refresh metrics"
                          >
                            Poll
                          </button>
                          <button
                            phx-click="remove_server"
                            phx-value-id={server.id}
                            data-confirm={"Are you sure you want to remove #{server.name}?"}
                            class="h-7 px-2 bg-transparent hover:bg-destructive/10 text-destructive/80 hover:text-destructive text-xs font-mono rounded transition-colors"
                            title="Delete server"
                          >
                            Delete
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </main>
    </div>

    <!-- Add Host Modal -->
    <%= if @add_modal do %>
      <div class="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-center justify-center z-50 p-4">
        <div class="shadcn-card bg-card border border-border rounded-lg w-full max-w-md p-6 shadow-2xl animate-fade-in font-mono">
          <div class="flex items-center justify-between pb-3 border-b border-border mb-4">
            <h2 class="text-sm font-semibold text-foreground uppercase tracking-wider">Register SSH Host</h2>
            <button phx-click="close_add_modal" class="text-muted-foreground hover:text-foreground transition-colors text-lg leading-none">&times;</button>
          </div>

          <%= if @error do %>
            <div class="mb-4 px-3 py-2 bg-destructive/10 border border-destructive/20 rounded text-destructive text-xs font-mono">
              <%= @error %>
            </div>
          <% end %>

          <form phx-change="form_change" phx-submit="add_server" autocomplete="off" class="space-y-3.5 text-xs">
            <div>
              <label class="block text-[11px] text-muted-foreground uppercase tracking-wider mb-1">Host Label</label>
              <input
                type="text"
                name="name"
                value={@new_name}
                phx-debounce="200"
                placeholder="Production Node"
                autocomplete="off"
                class="w-full h-8 px-3 bg-background border border-border focus:border-ring focus:outline-none rounded text-foreground text-xs"
              />
            </div>
            <div>
              <label class="block text-[11px] text-muted-foreground uppercase tracking-wider mb-1">Host / IP Address</label>
              <input
                type="text"
                name="host"
                value={@new_host}
                phx-debounce="200"
                placeholder="192.168.1.50"
                autocomplete="off"
                class="w-full h-8 px-3 bg-background border border-border focus:border-ring focus:outline-none rounded text-foreground text-xs"
              />
            </div>
            <div class="grid grid-cols-3 gap-2">
              <div class="col-span-2">
                <label class="block text-[11px] text-muted-foreground uppercase tracking-wider mb-1">Default User</label>
                <input
                  type="text"
                  name="user"
                  value={@new_user}
                  phx-debounce="200"
                  placeholder="root"
                  autocomplete="off"
                  class="w-full h-8 px-3 bg-background border border-border focus:border-ring focus:outline-none rounded text-foreground text-xs"
                />
              </div>
              <div>
                <label class="block text-[11px] text-muted-foreground uppercase tracking-wider mb-1">Port</label>
                <input
                  type="number"
                  name="port"
                  value={@new_port}
                  phx-debounce="200"
                  placeholder="22"
                  autocomplete="off"
                  class="w-full h-8 px-3 bg-background border border-border focus:border-ring focus:outline-none rounded text-foreground text-xs"
                />
              </div>
            </div>
            <div>
              <label class="block text-[11px] text-muted-foreground uppercase tracking-wider mb-1">Additional Users (comma-separated)</label>
              <input
                type="text"
                name="users"
                value={@new_users}
                phx-debounce="200"
                placeholder="deploy, admin, ops"
                autocomplete="off"
                class="w-full h-8 px-3 bg-background border border-border focus:border-ring focus:outline-none rounded text-foreground text-xs"
              />
            </div>
            <div>
              <label class="block text-[11px] text-muted-foreground uppercase tracking-wider mb-1">Authentication Method</label>
              <select
                name="auth_method"
                class="w-full h-8 px-2 bg-background border border-border focus:border-ring focus:outline-none rounded text-foreground text-xs"
              >
                <option value="key" selected={@new_auth_method == "key"}>SSH Key Authentication</option>
                <option value="password" selected={@new_auth_method == "password"}>Password Authentication</option>
              </select>
            </div>
            <div>
              <label class="block text-[11px] text-muted-foreground uppercase tracking-wider mb-1">
                Password <%= if @new_auth_method == "password", do: "(Required for password auth)", else: "(Optional, saved in vault)" %>
              </label>
              <input
                type="password"
                name="password"
                value={@new_password}
                phx-debounce="200"
                placeholder="Enter password"
                autocomplete="new-password"
                class="w-full h-8 px-3 bg-background border border-border focus:border-ring focus:outline-none rounded text-foreground text-xs"
              />
            </div>
            <div class="flex items-center gap-2 pt-1">
              <input
                type="checkbox"
                id="add_remember_password"
                name="remember_password"
                value="true"
                checked={@new_remember_password}
                class="rounded border-border text-primary focus:ring-ring"
              />
              <label for="add_remember_password" class="text-[11px] text-muted-foreground select-none cursor-pointer">
                Store password securely in OS Keychain
              </label>
            </div>
            <div class="flex gap-2 pt-3 border-t border-border">
              <button
                type="button"
                phx-click="close_add_modal"
                class="h-8 flex-1 bg-secondary text-secondary-foreground hover:bg-secondary/80 border border-border text-xs font-mono rounded transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="h-8 flex-1 bg-primary text-primary-foreground hover:bg-primary/90 text-xs font-mono font-medium rounded transition-colors shadow-sm"
              >
                Save Host
              </button>
            </div>
          </form>
        </div>
      </div>
    <% end %>

    <!-- Connect Modal -->
    <%= if @connect_modal and @connect_server do %>
      <div class="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-center justify-center z-50 p-4">
        <div class="shadcn-card bg-card border border-border rounded-lg w-full max-w-md p-6 shadow-2xl animate-fade-in font-mono">
          <div class="flex items-center justify-between pb-3 border-b border-border mb-4">
            <div>
              <h2 class="text-sm font-semibold text-foreground uppercase tracking-wider">Connect: <%= @connect_server.name %></h2>
              <p class="text-[11px] text-muted-foreground mt-0.5"><%= @connect_server.host %>:<%= @connect_server.port %></p>
            </div>
            <button phx-click="close_connect_modal" class="text-muted-foreground hover:text-foreground transition-colors text-lg leading-none">&times;</button>
          </div>

          <form phx-submit="submit_connect" class="space-y-4 text-xs">
            <div>
              <label class="block text-[11px] text-muted-foreground uppercase tracking-wider mb-2">Select User Account</label>
              <div class="flex flex-wrap gap-1.5 mb-2">
                <%= for u <- @connect_users do %>
                  <button
                    type="button"
                    phx-click="select_connect_user"
                    phx-value-user={u}
                    class={["px-2.5 py-1 text-xs rounded border transition-colors",
                      if(@connect_user == u, do: "bg-primary text-primary-foreground font-bold border-primary", else: "bg-secondary border-border text-muted-foreground hover:text-foreground hover:border-muted-foreground")]}
                  >
                    <%= u %>
                  </button>
                <% end %>
                <button
                  type="button"
                  phx-click="select_connect_user"
                  phx-value-user="custom"
                  class={["px-2.5 py-1 text-xs rounded border transition-colors",
                    if(@connect_user == "custom", do: "bg-primary text-primary-foreground font-bold border-primary", else: "bg-secondary border-border text-muted-foreground hover:text-foreground hover:border-muted-foreground")]}
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
                  class="w-full h-8 px-3 bg-background border border-border focus:border-ring focus:outline-none rounded text-foreground text-xs"
                />
              <% end %>
            </div>

            <div>
              <label class="block text-[11px] text-muted-foreground uppercase tracking-wider mb-1.5">Authentication Mode</label>
              <div class="grid grid-cols-2 gap-2 p-1 bg-muted/60 border border-border rounded">
                <button
                  type="button"
                  phx-click="set_connect_auth_method"
                  phx-value-method="key"
                  class={["py-1 text-xs rounded transition-colors text-center font-medium",
                    if(@connect_auth_method == :key, do: "bg-background text-foreground shadow-sm", else: "text-muted-foreground hover:text-foreground")]}
                >
                  SSH Key
                </button>
                <button
                  type="button"
                  phx-click="set_connect_auth_method"
                  phx-value-method="password"
                  class={["py-1 text-xs rounded transition-colors text-center font-medium",
                    if(@connect_auth_method == :password, do: "bg-background text-foreground shadow-sm", else: "text-muted-foreground hover:text-foreground")]}
                >
                  Password
                </button>
              </div>
              <input type="hidden" name="auth_method" value={to_string(@connect_auth_method)} />
            </div>

            <%= if @connect_auth_method == :password do %>
              <div class="space-y-2">
                <%= if @has_saved_password do %>
                  <div class="px-3 py-2 bg-emerald-500/10 border border-emerald-500/20 rounded text-emerald-500 text-[11px]">
                    Saved password available in Keychain
                  </div>
                <% end %>

                <div>
                  <label class="block text-[11px] text-muted-foreground uppercase tracking-wider mb-1">
                    <%= if @has_saved_password, do: "Override Password (optional)", else: "Server Password" %>
                  </label>
                  <input
                    type="password"
                    name="password"
                    value={@connect_password}
                    placeholder={if @has_saved_password, do: "Leave empty to use saved credentials", else: "Enter server password"}
                    class="w-full h-8 px-3 bg-background border border-border focus:border-ring focus:outline-none rounded text-foreground text-xs"
                  />
                </div>

                <div class="flex items-center gap-2 pt-0.5">
                  <input
                    type="checkbox"
                    id="remember_keychain"
                    name="remember"
                    value="true"
                    checked={@connect_remember}
                    class="rounded border-border text-primary focus:ring-ring"
                  />
                  <label for="remember_keychain" class="text-[11px] text-muted-foreground select-none cursor-pointer">
                    Remember password in Keychain
                  </label>
                </div>
              </div>
            <% end %>

            <div class="flex gap-2 pt-3 border-t border-border">
              <button
                type="submit"
                name="action"
                value="terminal"
                class="h-8 flex-1 bg-primary text-primary-foreground hover:bg-primary/90 text-xs font-mono font-medium rounded transition-colors shadow-sm"
              >
                Launch Terminal
              </button>
              <button
                type="submit"
                name="action"
                value="sftp"
                class="h-8 px-3 bg-secondary hover:bg-secondary/80 text-secondary-foreground border border-border text-xs font-mono rounded transition-colors"
              >
                SFTP
              </button>
              <button
                type="button"
                phx-click="close_connect_modal"
                class="h-8 px-3 text-muted-foreground hover:text-foreground text-xs font-mono rounded transition-colors"
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
end
