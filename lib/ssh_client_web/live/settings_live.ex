defmodule SSHClientWeb.SettingsLive do
  @moduledoc """
  Settings & Diagnostics LiveView — displays app version, configuration paths,
  discovered SSH keys, known_hosts statistics, in-app update checks, and
  tools to import hosts from OpenSSH ~/.ssh/config.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}

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

      socket =
        socket
        |> assign(:page_title, "Settings — ssh-client")
        |> assign(:current_tab, :general)
        |> assign(:config_path, config_path)
        |> assign(:known_hosts_path, known_hosts_path)
        |> assign(:known_hosts_count, length(known_hosts_entries))
        |> assign(:discovered_keys, discovered_keys)
        |> assign(:active_servers_count, length(active_servers))
        |> assign(:version, Updater.current_version())
        |> assign(:platform, detect_platform())
        |> assign(:checking_update, false)
        |> assign(:update_info, nil)
        |> assign(:update_error, nil)
        |> assign(:downloading_update, false)
        |> assign(:download_progress, 0)
        |> assign(:download_path, nil)
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
        result = Updater.download_update(url, name, caller_pid: caller)
        send(caller, {:update_download_complete, result})
      end)

      {:noreply,
       assign(socket,
         downloading_update: true,
         download_progress: 10,
         install_status: :downloading,
         install_error: nil,
         install_message: "Downloading update package..."
       )}
    else
      {:noreply, assign(socket, install_error: "No download asset found for current operating system.")}
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

  def handle_info({:update_download_complete, {:ok, path}}, socket) do
    case Updater.install_update(path) do
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
    <div class="flex h-full min-h-screen bg-[#050505]">
      <!-- Sidebar -->
      <aside class="w-56 bg-[#0a0a0a] border-r border-[#1f1f1f] flex flex-col justify-between shrink-0">
        <div>
          <div class="px-5 py-4 border-b border-[#1f1f1f] flex items-center justify-between">
            <a href="/" class="flex items-center gap-3">
              <img src="/images/icon.png" alt="Logo" class="w-7 h-7 rounded-lg" />
              <div>
                <span class="text-white font-semibold text-sm tracking-tight block">ssh-client</span>
                <span class="block text-[10px] text-zinc-600 font-mono">v<%= @version %></span>
              </div>
            </a>
            <span class="px-1.5 py-0.5 text-[9px] font-mono font-semibold uppercase tracking-wider rounded bg-red-500/10 text-red-400 border border-red-500/20">BETA</span>
          </div>

          <nav class="flex-1 px-3 py-4 space-y-0.5">
            <a
              href="/"
              class="flex items-center gap-2.5 px-3 py-2 rounded-lg text-zinc-500 hover:text-zinc-300 hover:bg-white/5 text-sm font-medium transition-colors"
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
              class="flex items-center gap-2.5 px-3 py-2 rounded-lg bg-blue-600/10 text-blue-400 text-sm font-medium"
            >
              Settings
            </a>
          </nav>
        </div>

        <div class="px-5 py-4 border-t border-[#1f1f1f] flex items-center justify-between">
          <span class="text-[11px] text-zinc-700 font-mono">
            <%= @active_servers_count %> host<%= if @active_servers_count != 1, do: "s" %>
          </span>
          <button
            phx-click="lock_vault"
            class="text-[10px] text-zinc-600 hover:text-zinc-400 font-mono transition-colors"
            title="Lock Vault"
          >
            Lock
          </button>
        </div>
      </aside>

      <!-- Main content -->
      <div class="flex-1 flex flex-col min-w-0 overflow-auto">
        <!-- Topbar -->
        <header class="h-14 flex items-center justify-between px-8 border-b border-[#1f1f1f] bg-[#050505] shrink-0">
          <div class="flex items-center gap-3">
            <h1 class="text-sm font-semibold text-white tracking-tight">Application Settings & Diagnostics</h1>
          </div>
          <div class="flex items-center gap-2">
            <button
              phx-click="check_update"
              disabled={@checking_update or @downloading_update}
              class="h-8 px-3 bg-blue-600 hover:bg-blue-500 disabled:opacity-50 text-white text-xs font-medium rounded-lg transition-colors inline-flex items-center gap-1.5"
            >
              <%= if @checking_update do %>
                <span class="w-3 h-3 border-2 border-white border-t-transparent rounded-full animate-spin"></span>
                Checking...
              <% else %>
                Check for Updates
              <% end %>
            </button>
          </div>
        </header>

        <!-- Content Area -->
        <div class="p-8 max-w-4xl space-y-6">
          <!-- Update Status Card (if checked) -->
          <%= if @update_info do %>
            <div class={["p-6 rounded-2xl border transition-all",
              if(@update_info.update_available?, do: "bg-blue-950/20 border-blue-500/40", else: "bg-[#0a0a0a] border-[#1f1f1f]")]}>
              <div class="flex flex-col sm:flex-row sm:items-start justify-between gap-4">
                <div class="space-y-1">
                  <div class="flex items-center gap-2.5">
                    <span class={["w-2.5 h-2.5 rounded-full", if(@update_info.update_available?, do: "bg-blue-400 animate-pulse", else: "bg-emerald-400")]}></span>
                    <h3 class="text-base font-semibold text-white">
                      <%= if @update_info.update_available? do %>
                        New Version Available: <%= @update_info.tag_name %>
                      <% else %>
                        ssh-client is up to date (v<%= @version %>)
                      <% end %>
                    </h3>
                  </div>
                  <p class="text-xs text-zinc-400 font-mono">
                    Current installed: v<%= @version %> &bull; Latest release: <%= @update_info.tag_name %>
                  </p>
                </div>

                <%= if @update_info.update_available? do %>
                  <div class="flex items-center gap-2 shrink-0">
                    <%= if @downloading_update do %>
                      <div class="px-4 py-2 bg-blue-600/30 border border-blue-500/40 rounded-xl text-xs font-mono text-blue-300 flex items-center gap-2">
                        <span class="w-3 h-3 border-2 border-blue-400 border-t-transparent rounded-full animate-spin"></span>
                        Downloading (<%= @download_progress %>%)
                      </div>
                    <% else %>
                      <button
                        phx-click="start_in_app_update"
                        class="px-4 py-2 bg-blue-600 hover:bg-blue-500 text-white text-xs font-semibold rounded-xl transition-all shadow-lg shadow-blue-900/30 inline-flex items-center gap-1.5"
                      >
                        Download &amp; Install Update
                      </button>
                      <a
                        href={@update_info.release_url}
                        target="_blank"
                        class="px-3 py-2 bg-[#141414] hover:bg-[#1f1f1f] border border-[#262626] text-zinc-300 text-xs font-medium rounded-xl transition-colors"
                      >
                        GitHub Release ↗
                      </a>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <!-- Live Download Progress Bar -->
              <%= if @downloading_update do %>
                <div class="mt-4 pt-4 border-t border-blue-500/20 space-y-2">
                  <div class="flex justify-between text-xs font-mono text-blue-300">
                    <span>Downloading update payload...</span>
                    <span><%= @download_progress %>%</span>
                  </div>
                  <div class="w-full h-2 bg-[#111] rounded-full overflow-hidden border border-blue-500/30">
                    <div class="h-full bg-blue-500 transition-all duration-300 rounded-full" style={"width: #{@download_progress}%"}></div>
                  </div>
                </div>
              <% end %>

              <!-- Installation Success/Status message -->
              <%= if @install_status == :installed do %>
                <div class="mt-4 p-4 rounded-xl bg-emerald-500/10 border border-emerald-500/30 text-emerald-300 text-xs font-mono flex items-center justify-between gap-3">
                  <div>
                    <span class="font-semibold block text-emerald-200">Update Ready:</span>
                    <%= @install_message %>
                  </div>
                  <%= if @download_path do %>
                    <button
                      phx-click="launch_installer"
                      class="px-3 py-1.5 bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-medium rounded-lg shrink-0 transition-colors"
                    >
                      Run Installer
                    </button>
                  <% end %>
                </div>
              <% end %>

              <%= if @install_error do %>
                <div class="mt-4 p-4 rounded-xl bg-red-500/10 border border-red-500/30 text-red-400 text-xs font-mono">
                  <%= @install_error %>
                </div>
              <% end %>

              <!-- Manual download options -->
              <%= if @update_info.update_available? and @update_info.assets != [] do %>
                <div class="mt-4 pt-4 border-t border-[#1f1f1f] space-y-2">
                  <span class="text-[11px] text-zinc-500 uppercase tracking-wider block font-mono">Platform Packages</span>
                  <div class="flex flex-wrap gap-2">
                    <%= for asset <- @update_info.assets do %>
                      <button
                        phx-click="start_in_app_update"
                        phx-value-url={asset.browser_download_url}
                        phx-value-name={asset.name}
                        class="px-3 py-1.5 bg-[#111] hover:bg-[#1a1a1a] border border-[#222] hover:border-zinc-700 text-xs text-zinc-300 font-mono rounded-lg transition-colors inline-flex items-center gap-2 text-left"
                      >
                        <span class="text-white font-medium"><%= asset.name %></span>
                        <span class="text-zinc-600 text-[10px]">(<%= format_bytes(asset.size) %>)</span>
                      </button>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= if @update_error do %>
            <div class="p-4 rounded-xl bg-red-500/10 border border-red-500/20 text-red-400 text-xs font-mono">
              Update check failed: <%= @update_error %>
            </div>
          <% end %>

          <!-- System & Paths Info -->
          <div class="bg-[#0a0a0a] border border-[#1f1f1f] rounded-2xl p-6 space-y-4">
            <h2 class="text-sm font-semibold text-white">System & Configuration</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-xs font-mono">
              <div class="p-3.5 bg-[#111] border border-[#1a1a1a] rounded-xl space-y-1">
                <span class="text-zinc-500 uppercase tracking-wider text-[10px] block">Platform</span>
                <span class="text-zinc-200"><%= @platform %></span>
              </div>
              <div class="p-3.5 bg-[#111] border border-[#1a1a1a] rounded-xl space-y-1">
                <span class="text-zinc-500 uppercase tracking-wider text-[10px] block">Application Version</span>
                <span class="text-zinc-200">v<%= @version %></span>
              </div>
              <div class="p-3.5 bg-[#111] border border-[#1a1a1a] rounded-xl space-y-1 md:col-span-2">
                <span class="text-zinc-500 uppercase tracking-wider text-[10px] block">Config File Path</span>
                <span class="text-zinc-300 break-all"><%= @config_path %></span>
              </div>
              <div class="p-3.5 bg-[#111] border border-[#1a1a1a] rounded-xl space-y-1 md:col-span-2">
                <div class="flex items-center justify-between">
                  <span class="text-zinc-500 uppercase tracking-wider text-[10px] block">Known Hosts Path</span>
                  <span class="text-[11px] text-zinc-500"><%= @known_hosts_count %> verified entries</span>
                </div>
                <span class="text-zinc-300 break-all"><%= @known_hosts_path %></span>
              </div>
            </div>
          </div>

          <!-- SSH Key Discovery -->
          <div class="bg-[#0a0a0a] border border-[#1f1f1f] rounded-2xl p-6 space-y-4">
            <div class="flex items-center justify-between">
              <div>
                <h2 class="text-sm font-semibold text-white">Discovered SSH Private Keys</h2>
                <p class="text-xs text-zinc-500 mt-0.5">Identities discovered in ~/.ssh used automatically for authentication.</p>
              </div>
              <span class="text-[11px] text-zinc-600 font-mono"><%= length(@discovered_keys) %> detected</span>
            </div>

            <%= if @discovered_keys == [] do %>
              <div class="p-4 bg-[#111] border border-[#1a1a1a] rounded-xl text-xs text-zinc-500 font-mono">
                No standard private keys (id_ed25519, id_rsa, id_ecdsa) found in ~/.ssh.
              </div>
            <% else %>
              <div class="space-y-2">
                <%= for key_path <- @discovered_keys do %>
                  <div class="flex items-center justify-between p-3 bg-[#111] border border-[#1a1a1a] rounded-xl text-xs font-mono">
                    <span class="text-zinc-300"><%= key_path %></span>
                    <span class="px-2 py-0.5 rounded text-[10px] bg-emerald-500/10 text-emerald-400 border border-emerald-500/20">ready</span>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <!-- Import OpenSSH Config -->
          <div class="bg-[#0a0a0a] border border-[#1f1f1f] rounded-2xl p-6 space-y-4">
            <div class="flex items-center justify-between">
              <div>
                <h2 class="text-sm font-semibold text-white">Import from OpenSSH ~/.ssh/config</h2>
                <p class="text-xs text-zinc-500 mt-0.5">Scan your existing SSH config file and import configured hosts into ssh-client.</p>
              </div>
              <button
                phx-click="scan_ssh_config"
                class="h-8 px-3 bg-[#111] hover:bg-[#1a1a1a] border border-[#1f1f1f] hover:border-zinc-600 text-zinc-300 text-xs rounded-lg transition-colors font-medium"
              >
                Scan ~/.ssh/config
              </button>
            </div>

            <%= if @import_status do %>
              <div class="p-3 bg-[#111] border border-[#1a1a1a] rounded-xl text-xs text-zinc-400 font-mono">
                <%= @import_status %>
              </div>
            <% end %>

            <%= if @import_candidates != [] do %>
              <div class="space-y-3 pt-2">
                <div class="flex items-center justify-between">
                  <span class="text-xs text-zinc-400 font-semibold">Found Hosts to Import:</span>
                  <button
                    phx-click="import_all_candidates"
                    class="h-8 px-4 bg-blue-600 hover:bg-blue-500 text-white text-xs font-medium rounded-lg transition-colors"
                  >
                    Import <%= length(@import_candidates) %> Hosts
                  </button>
                </div>

                <div class="space-y-1.5 max-h-48 overflow-auto border border-[#1f1f1f] rounded-xl p-2 bg-[#050505]">
                  <%= for cand <- @import_candidates do %>
                    <div class="flex items-center justify-between p-2 rounded-lg bg-[#111] text-xs font-mono">
                      <span class="text-zinc-200 font-medium"><%= cand.id %></span>
                      <span class="text-zinc-500"><%= cand.user %>@<%= cand.address %>:<%= cand.port || 22 %></span>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
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
