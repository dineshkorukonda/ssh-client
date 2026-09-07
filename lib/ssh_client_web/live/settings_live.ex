defmodule SSHClientWeb.SettingsLive do
  @moduledoc """
  Settings & Diagnostics LiveView — displays app version, configuration paths,
  discovered SSH keys, known_hosts statistics, in-app update checks, and
  tools to import hosts from OpenSSH ~/.ssh/config.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}
  import SSHClientWeb.CoreComponents

  alias SSHClient.Config
  alias SSHClient.ServerManager
  alias SSHClient.SSH.Auth
  alias SSHClient.SSH.ConfigImporter
  alias SSHClient.SSH.HostKeyVerifier
  alias SSHClient.Updater
  alias SSHClient.Vault

  @impl true
  def mount(_params, _session, socket) do
    if not Vault.unlocked?() do
      {:ok, push_navigate(socket, to: "/lock")}
    else
      config_path = Config.default_config_path()
      known_hosts_path = HostKeyVerifier.known_hosts_path()
      known_hosts_entries = HostKeyVerifier.load_known_hosts()
      discovered_keys = Auth.resolve_identities()
      active_servers = list_active_servers()
      online_count = count_online_servers()

      socket =
        socket
        |> assign(:page_title, "Settings — ssh-client")
        |> assign(:current_tab, :general)
        |> assign(:config_path, config_path)
        |> assign(:known_hosts_path, known_hosts_path)
        |> assign(:known_hosts_count, length(known_hosts_entries))
        |> assign(:discovered_keys, discovered_keys)
        |> assign(:active_servers_count, length(active_servers))
        |> assign(:online_count, online_count)
        |> assign(:version, Updater.current_version())
        |> assign(:platform, detect_platform())
        |> assign(:checking_update, false)
        |> assign(:update_info, nil)
        |> assign(:update_error, nil)
        |> assign(:downloading_update, false)
        |> assign(:download_progress, 0)
        |> assign(:download_path, nil)
        |> assign(:staged_dir, nil)
        |> assign(:install_status, nil)
        |> assign(:install_message, nil)
        |> assign(:install_error, nil)
        |> assign(:import_candidates, [])
        |> assign(:import_status, nil)

      {:ok, socket}
    end
  end

  @impl true
  def handle_event("check_update", _params, socket) do
    socket = assign(socket, checking_update: true, update_error: nil, install_status: nil, install_error: nil)

    case Updater.check_update() do
      {:ok, info} ->
        {:noreply, assign(socket, checking_update: false, update_info: info, update_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, checking_update: false, update_error: to_string(reason))}
    end
  end

  def handle_event("start_in_app_update", params, socket) do
    url =
      params["url"] ||
        (socket.assigns.update_info && socket.assigns.update_info.platform_asset &&
           socket.assigns.update_info.platform_asset.browser_download_url)

    name =
      params["name"] ||
        (socket.assigns.update_info && socket.assigns.update_info.platform_asset &&
           socket.assigns.update_info.platform_asset.name)

    if url && url != "" do
      caller = self()

      Task.start(fn ->
        ext = name |> Path.extname() |> String.downcase()

        if ext in [".zip", ".gz", ".tgz", ".tar"] do
          result = Updater.stage_in_place_update(url, name, caller_pid: caller)
          send(caller, {:update_stage_complete, result})
        else
          result = Updater.download_update(url, name, caller_pid: caller)
          send(caller, {:update_download_complete, result})
        end
      end)

      {:noreply,
       assign(socket,
         downloading_update: true,
         download_progress: 10,
         install_status: :downloading,
         install_error: nil,
         install_message: "Downloading update package in background..."
       )}
    else
      {:noreply, assign(socket, install_error: "No download asset found for current operating system.")}
    end
  end

  def handle_event("restart_and_apply", _params, socket) do
    staged = socket.assigns[:staged_dir]

    case Updater.apply_update_and_restart(staged) do
      {:ok, :restarting, msg} ->
        {:noreply, assign(socket, install_status: :restarting, install_message: msg)}

      {:error, reason} ->
        {:noreply, assign(socket, install_error: to_string(reason))}
    end
  end

  def handle_event("launch_installer", _params, socket) do
    if path = socket.assigns.download_path do
      case Updater.install_update(path) do
        {:ok, _status, msg} ->
          {:noreply, assign(socket, install_status: :installed, install_message: msg)}

        {:error, reason} ->
          {:noreply, assign(socket, install_error: to_string(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("scan_ssh_config", _params, socket) do
    case ConfigImporter.import_file() do
      {:ok, hosts} ->
        existing = ServerManager.list_servers()
        new_hosts = ConfigImporter.deduplicate(hosts, existing)

        status =
          if new_hosts == [] do
            "No new hosts found in ~/.ssh/config (all #{length(hosts)} already registered or none present)."
          else
            "Found #{length(new_hosts)} host(s) available for import."
          end

        {:noreply, assign(socket, import_candidates: new_hosts, import_status: status)}

      {:error, reason} ->
        {:noreply, assign(socket, import_status: "Error scanning ~/.ssh/config: #{reason}")}
    end
  end

  def handle_event("import_all_candidates", _params, socket) do
    candidates = socket.assigns.import_candidates

    Enum.each(candidates, fn host ->
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

    active = list_active_servers()

    {:noreply,
     socket
     |> assign(:import_candidates, [])
     |> assign(:import_status, "Successfully imported #{length(candidates)} host(s) into ssh-client!")
     |> assign(:active_servers_count, length(active))}
  end

  def handle_event("lock_vault", _params, socket) do
    Vault.lock()
    {:noreply, push_navigate(socket, to: "/lock")}
  end

  @impl true
  def handle_info({:update_download_progress, percent, _done, _total}, socket) do
    {:noreply, assign(socket, download_progress: percent)}
  end

  def handle_info({:update_stage_complete, {:ok, %{staged_dir: staged, archive_path: path}}}, socket) do
    {:noreply,
     assign(socket,
       downloading_update: false,
       download_progress: 100,
       download_path: path,
       staged_dir: staged,
       install_status: :ready_to_restart,
       install_message:
         "Update payload staged and verified. Click 'Restart & Apply Update' to switch instantly."
     )}
  end

  def handle_info({:update_stage_complete, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       downloading_update: false,
       install_status: nil,
       install_error: "Update staging failed: #{reason}"
     )}
  end

  def handle_info({:update_download_complete, {:ok, path}}, socket) do
    case Updater.install_update(path) do
      {:ok, :ready_to_restart, msg} ->
        {:noreply,
         assign(socket,
           downloading_update: false,
           download_progress: 100,
           download_path: path,
           staged_dir: Path.join(Updater.staging_dir(), "unpacked"),
           install_status: :ready_to_restart,
           install_message: msg
         )}

      {:ok, _status, msg} ->
        {:noreply,
         assign(socket,
           downloading_update: false,
           download_progress: 100,
           download_path: path,
           install_status: :installed,
           install_message: msg
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           downloading_update: false,
           download_progress: 100,
           download_path: path,
           install_status: :ready_to_install,
           install_error: reason
         )}
    end
  end

  def handle_info({:update_download_complete, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       downloading_update: false,
       install_status: nil,
       install_error: "Download failed: #{reason}"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background text-foreground flex flex-col antialiased">
      <.top_navigation
        current_tab={:settings}
        servers_count={@active_servers_count}
        online_count={@online_count}
        version={@version}
      />

      <main class="flex-1 container mx-auto max-w-5xl px-4 py-6 flex flex-col space-y-6">
        <!-- Header -->
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pb-2 border-b border-border/60">
          <div>
            <h1 class="text-xl font-bold tracking-tight text-foreground font-sans">Settings & System Diagnostics</h1>
            <p class="text-xs text-muted-foreground font-mono mt-0.5">
              Manage application telemetry, release updates, SSH key discovery, and host imports.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button
              phx-click="check_update"
              disabled={@checking_update or @downloading_update}
              class="inline-flex items-center justify-center gap-2 h-8 px-4 rounded-md bg-primary text-primary-foreground hover:bg-primary/90 text-xs font-mono font-medium shadow-xs transition-colors disabled:opacity-50"
            >
              <%= if @checking_update do %>
                <span class="w-3 h-3 border-2 border-primary-foreground border-t-transparent rounded-full animate-spin"></span>
                Checking...
              <% else %>
                <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
                </svg>
                Check for Updates
              <% end %>
            </button>
          </div>
        </div>

        <!-- Update Status Card (if checked) -->
        <%= if @update_info do %>
          <div class={["p-6 rounded-xl border transition-all shadow-xs",
            if(@update_info.update_available?, do: "bg-primary/5 border-primary/40", else: "bg-card border-border")]}>
            <div class="flex flex-col sm:flex-row sm:items-start justify-between gap-4">
              <div class="space-y-1">
                <div class="flex items-center gap-2.5">
                  <span class={["w-2.5 h-2.5 rounded-full", if(@update_info.update_available?, do: "bg-primary animate-pulse", else: "bg-emerald-500")]}></span>
                  <h3 class="text-base font-semibold text-foreground">
                    <%= if @update_info.update_available? do %>
                      New Release Available: <%= @update_info.tag_name %>
                    <% else %>
                      ssh-client is up to date (v<%= @version %>)
                    <% end %>
                  </h3>
                </div>
                <p class="text-xs text-muted-foreground font-mono">
                  Current installed: v<%= @version %> &bull; Latest release: <%= @update_info.tag_name %>
                </p>
              </div>

              <%= if @update_info.update_available? do %>
                <div class="flex items-center gap-2 shrink-0">
                  <%= if @downloading_update do %>
                    <div class="px-4 py-2 bg-primary/20 border border-primary/40 rounded-lg text-xs font-mono text-primary flex items-center gap-2">
                      <span class="w-3 h-3 border-2 border-primary border-t-transparent rounded-full animate-spin"></span>
                      Downloading (<%= @download_progress %>%)
                    </div>
                  <% else %>
                    <button
                      phx-click="start_in_app_update"
                      class="px-4 py-2 bg-primary hover:bg-primary/90 text-primary-foreground text-xs font-semibold rounded-lg transition-all shadow-xs inline-flex items-center gap-1.5"
                    >
                      Download &amp; Install Update
                    </button>
                    <a
                      href={@update_info.release_url}
                      target="_blank"
                      class="px-3 py-2 bg-secondary hover:bg-secondary/80 border border-border text-secondary-foreground text-xs font-medium rounded-lg transition-colors"
                    >
                      GitHub Release ↗
                    </a>
                  <% end %>
                </div>
              <% end %>
            </div>

            <!-- Live Download Progress Bar -->
            <%= if @downloading_update do %>
              <div class="mt-4 pt-4 border-t border-border space-y-2">
                <div class="flex justify-between text-xs font-mono text-primary">
                  <span>Downloading update payload...</span>
                  <span><%= @download_progress %>%</span>
                </div>
                <div class="w-full h-2 bg-muted rounded-full overflow-hidden border border-border">
                  <div class="h-full bg-primary transition-all duration-300 rounded-full" style={"width: #{@download_progress}%"}></div>
                </div>
              </div>
            <% end %>

            <!-- Ready to Restart (Zero-Wizard In-Place Hot-Swap) -->
            <%= if @install_status == :ready_to_restart do %>
              <div class="mt-4 p-4 rounded-lg bg-emerald-500/10 border border-emerald-500/30 text-emerald-600 dark:text-emerald-400 text-xs font-mono flex flex-col sm:flex-row sm:items-center justify-between gap-3">
                <div>
                  <span class="font-semibold block text-foreground">Update Ready:</span>
                  <%= @install_message %>
                </div>
                <button
                  phx-click="restart_and_apply"
                  class="px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-semibold rounded-lg shrink-0 transition-all shadow-xs"
                >
                  Restart &amp; Apply Update
                </button>
              </div>
            <% end %>

            <!-- Restarting State -->
            <%= if @install_status == :restarting do %>
              <div class="mt-4 p-4 rounded-lg bg-primary/10 border border-primary/30 text-primary text-xs font-mono flex items-center gap-2.5">
                <span class="w-3 h-3 border-2 border-primary border-t-transparent rounded-full animate-spin"></span>
                <span><%= @install_message %></span>
              </div>
            <% end %>

            <!-- Installation Success/Status message (Installer Fallback) -->
            <%= if @install_status == :installed do %>
              <div class="mt-4 p-4 rounded-lg bg-emerald-500/10 border border-emerald-500/30 text-emerald-600 dark:text-emerald-400 text-xs font-mono flex items-center justify-between gap-3">
                <div>
                  <span class="font-semibold block text-foreground">Update Ready:</span>
                  <%= @install_message %>
                </div>
                <%= if @download_path do %>
                  <button
                    phx-click="launch_installer"
                    class="px-3 py-1.5 bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-medium rounded-md shrink-0 transition-colors"
                  >
                    Run Installer
                  </button>
                <% end %>
              </div>
            <% end %>

            <%= if @install_error do %>
              <div class="mt-4 p-4 rounded-lg bg-destructive/10 border border-destructive/30 text-destructive text-xs font-mono">
                <%= @install_error %>
              </div>
            <% end %>

            <!-- Platform Packages List -->
            <%= if @update_info.update_available? and @update_info.assets != [] do %>
              <div class="mt-4 pt-4 border-t border-border space-y-2">
                <span class="text-[11px] text-muted-foreground uppercase tracking-wider block font-mono">Platform Packages</span>
                <div class="flex flex-wrap gap-2">
                  <%= for asset <- @update_info.assets do %>
                    <button
                      phx-click="start_in_app_update"
                      phx-value-url={asset.browser_download_url}
                      phx-value-name={asset.name}
                      class="px-3 py-1.5 bg-background hover:bg-muted border border-border hover:border-input text-xs text-foreground font-mono rounded-md transition-colors inline-flex items-center gap-2 text-left"
                    >
                      <span class="font-medium"><%= asset.name %></span>
                      <span class="text-muted-foreground text-[10px]">(<%= format_bytes(asset.size) %>)</span>
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if @update_error do %>
          <div class="p-4 rounded-lg bg-destructive/10 border border-destructive/20 text-destructive text-xs font-mono">
            Update check failed: <%= @update_error %>
          </div>
        <% end %>

        <!-- System & Paths Info -->
        <div class="bg-card border border-border rounded-xl p-6 space-y-4 shadow-xs">
          <div class="flex items-center justify-between pb-2 border-b border-border/60">
            <h2 class="text-sm font-semibold text-foreground">System & Environment Configuration</h2>
            <span class="text-xs text-muted-foreground font-mono">Local Node</span>
          </div>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-xs font-mono">
            <div class="p-3.5 bg-muted/40 border border-border/60 rounded-lg space-y-1">
              <span class="text-muted-foreground uppercase tracking-wider text-[10px] block font-sans font-semibold">Platform Architecture</span>
              <span class="text-foreground font-semibold"><%= @platform %></span>
            </div>
            <div class="p-3.5 bg-muted/40 border border-border/60 rounded-lg space-y-1">
              <span class="text-muted-foreground uppercase tracking-wider text-[10px] block font-sans font-semibold">Application Release</span>
              <span class="text-foreground font-semibold">v<%= @version %></span>
            </div>
            <div class="p-3.5 bg-muted/40 border border-border/60 rounded-lg space-y-1 md:col-span-2">
              <span class="text-muted-foreground uppercase tracking-wider text-[10px] block font-sans font-semibold">Local Store File Path</span>
              <span class="text-foreground break-all"><%= @config_path %></span>
            </div>
            <div class="p-3.5 bg-muted/40 border border-border/60 rounded-lg space-y-1 md:col-span-2">
              <div class="flex items-center justify-between">
                <span class="text-muted-foreground uppercase tracking-wider text-[10px] block font-sans font-semibold">Known Hosts Path</span>
                <span class="text-[11px] text-muted-foreground"><%= @known_hosts_count %> verified fingerprints</span>
              </div>
              <span class="text-foreground break-all"><%= @known_hosts_path %></span>
            </div>
          </div>
        </div>

        <!-- SSH Key Discovery -->
        <div class="bg-card border border-border rounded-xl p-6 space-y-4 shadow-xs">
          <div class="flex items-center justify-between pb-2 border-b border-border/60">
            <div>
              <h2 class="text-sm font-semibold text-foreground">Discovered SSH Private Keys</h2>
              <p class="text-xs text-muted-foreground mt-0.5">Identities discovered in ~/.ssh used automatically for public-key authentication.</p>
            </div>
            <span class="text-[11px] text-muted-foreground font-mono"><%= length(@discovered_keys) %> detected</span>
          </div>

          <%= if @discovered_keys == [] do %>
            <div class="p-4 bg-muted/30 border border-border rounded-lg text-xs text-muted-foreground font-mono">
              No standard private keys (id_ed25519, id_rsa, id_ecdsa) found in ~/.ssh.
            </div>
          <% else %>
            <div class="space-y-2">
              <%= for key_path <- @discovered_keys do %>
                <div class="flex items-center justify-between p-3 bg-muted/30 border border-border rounded-lg text-xs font-mono">
                  <span class="text-foreground font-medium"><%= key_path %></span>
                  <span class="px-2 py-0.5 rounded text-[10px] bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border border-emerald-500/20 font-semibold uppercase">ready</span>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <!-- Import OpenSSH Config -->
        <div class="bg-card border border-border rounded-xl p-6 space-y-4 shadow-xs">
          <div class="flex items-center justify-between pb-2 border-b border-border/60">
            <div>
              <h2 class="text-sm font-semibold text-foreground">Import from OpenSSH ~/.ssh/config</h2>
              <p class="text-xs text-muted-foreground mt-0.5">Scan existing SSH client configurations and register hosts automatically.</p>
            </div>
            <button
              phx-click="scan_ssh_config"
              class="h-8 px-3 bg-secondary hover:bg-secondary/80 border border-border text-secondary-foreground text-xs rounded-md transition-colors font-medium inline-flex items-center gap-1.5"
            >
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
              </svg>
              Scan ~/.ssh/config
            </button>
          </div>

          <%= if @import_status do %>
            <div class="p-3 bg-muted/40 border border-border rounded-lg text-xs text-foreground font-mono">
              <%= @import_status %>
            </div>
          <% end %>

          <%= if @import_candidates != [] do %>
            <div class="space-y-3 pt-2">
              <div class="flex items-center justify-between">
                <span class="text-xs text-foreground font-semibold">Available Hosts to Import:</span>
                <button
                  phx-click="import_all_candidates"
                  class="h-8 px-4 bg-primary text-primary-foreground hover:bg-primary/90 text-xs font-medium rounded-md shadow-xs transition-colors"
                >
                  Import <%= length(@import_candidates) %> Hosts
                </button>
              </div>

              <div class="space-y-1.5 max-h-48 overflow-auto border border-border rounded-lg p-2 bg-muted/20">
                <%= for cand <- @import_candidates do %>
                  <div class="flex items-center justify-between p-2 rounded-md bg-card border border-border/50 text-xs font-mono">
                    <span class="text-foreground font-medium"><%= cand.id %></span>
                    <span class="text-muted-foreground"><%= cand.user %>@<%= cand.address %>:<%= cand.port || 22 %></span>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </main>
    </div>
    """
  end

  defp list_active_servers do
    try do
      ServerManager.list_servers()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp count_online_servers do
    try do
      ServerManager.list_servers()
      |> Enum.count(fn s ->
        status = s[:status] || s["status"]
        status in ["online", "healthy", :online, :healthy]
      end)
    rescue
      _ -> 0
    catch
      :exit, _ -> 0
    end
  end

  defp detect_platform do
    case :os.type() do
      {:win32, _} -> "Windows (win32)"
      {:unix, :darwin} -> "macOS (darwin)"
      {:unix, _} -> "Linux (unix)"
      _ -> "Unknown"
    end
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_048_576 -> "#{:erlang.float_to_binary(bytes / 1_048_576, decimals: 1)} MB"
      bytes >= 1024 -> "#{:erlang.float_to_binary(bytes / 1024, decimals: 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "0 B"
end

