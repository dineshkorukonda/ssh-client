defmodule SSHClientWeb.TerminalLive do
  @moduledoc """
  Phoenix LiveView hosting the interactive xterm.js embedded terminal.
  Supervises a PTYSession process, bridges bidirectional I/O, handles
  window resize, and outputs real-time diagnostics.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}

  alias SSHClient.ActivityLog
  alias SSHClient.Config
  alias SSHClient.Config.Server
  alias SSHClient.ServerManager
  alias SSHClient.SSH.PTYSession
  alias SSHClient.TerminalSupervisor

  @default_commands [
    # Zsh & Shell
    %{cmd: "exec zsh -l", label: "Switch to Zsh Shell", desc: "Launches interactive login Zsh session", cat: "zsh"},
    %{cmd: "source ~/.zshrc", label: "Reload Zsh Config", desc: "Re-sources ~/.zshrc profile", cat: "zsh"},
    %{cmd: "echo $SHELL", label: "Check Active Shell", desc: "Displays current default shell path", cat: "zsh"},
    %{cmd: "which zsh bash fish", label: "Find Installed Shells", desc: "Checks binary paths for common shells", cat: "zsh"},
    %{cmd: "chsh -s $(which zsh)", label: "Set Default Shell to Zsh", desc: "Changes login shell for current user", cat: "zsh"},

    # System & Hardware
    %{cmd: "htop", label: "Interactive Process Monitor (htop)", desc: "Interactive process and core monitor", cat: "sys"},
    %{cmd: "df -h", label: "Disk Space Usage (df -h)", desc: "Show available filesystem disk space", cat: "sys"},
    %{cmd: "free -h", label: "Memory Usage (free -h)", desc: "Display RAM & swap usage in human units", cat: "sys"},
    %{cmd: "uptime", label: "System Uptime & Load", desc: "Shows system uptime and 1/5/15m load average", cat: "sys"},
    %{cmd: "uname -a", label: "Kernel & Architecture", desc: "Outputs OS kernel release and architecture", cat: "sys"},
    %{cmd: "vmstat 1 5", label: "Virtual Memory Stats", desc: "Samples virtual memory, IO, and CPU activity", cat: "sys"},

    # Docker & Containers
    %{cmd: "docker ps -a", label: "List All Containers", desc: "Shows all running and stopped containers", cat: "docker"},
    %{cmd: "docker stats --no-stream", label: "Container Resource Stats", desc: "Live memory and CPU per container", cat: "docker"},
    %{cmd: "docker compose ps", label: "Compose Services Status", desc: "Lists all docker-compose managed services", cat: "docker"},
    %{cmd: "docker compose up -d", label: "Start Compose Stack", desc: "Spawns compose services in background", cat: "docker"},
    %{cmd: "docker compose logs -f --tail 100", label: "Follow Compose Logs", desc: "Follows last 100 log lines from services", cat: "docker"},

    # Services & Logs
    %{cmd: "systemctl status ssh", label: "SSH Service Status", desc: "Checks SSH daemon health and logs", cat: "services"},
    %{cmd: "systemctl list-units --type=service --state=running", label: "List Running Services", desc: "Lists all active systemd units", cat: "services"},
    %{cmd: "journalctl -xe -n 50", label: "Recent System Errors", desc: "Views last 50 error journal entries", cat: "services"},
    %{cmd: "tail -f /var/log/syslog", label: "Follow System Log", desc: "Real-time stream of /var/log/syslog", cat: "services"},

    # Network
    %{cmd: "ss -tulpn", label: "Listening Ports (ss)", desc: "Lists listening TCP/UDP sockets with PIDs", cat: "net"},
    %{cmd: "ip a", label: "IP Addresses & Interfaces", desc: "Shows IP addresses for all network devices", cat: "net"},
    %{cmd: "curl -I https://google.com", label: "HTTP Header Probe", desc: "Checks internet connectivity & DNS", cat: "net"},
    %{cmd: "ping -c 4 1.1.1.1", label: "Ping Cloudflare DNS", desc: "Tests latency with 4 ICMP packets", cat: "net"},
    %{cmd: "ufw status verbose", label: "Firewall Status (UFW)", desc: "Inspects active firewall rules and policies", cat: "net"},

    # Files & Storage
    %{cmd: "du -sh * | sort -h", label: "Directory Sizes", desc: "Sorts folders in current path by disk usage", cat: "files"},
    %{cmd: "find . -type f -size +100M", label: "Find Large Files (>100M)", desc: "Locates large files taking up disk space", cat: "files"},
    %{cmd: "ls -la --color=auto", label: "Detailed File List", desc: "Lists all files with permissions and owners", cat: "files"}
  ]

  @impl true
  def mount(%{"id" => server_id}, _session, socket) do
    server = resolve_server_struct(server_id)

    socket =
      socket
      |> assign(:page_title, "Terminal — #{server_id}")
      |> assign(:server_id, server_id)
      |> assign(:server, server)
      |> assign(:session_pid, nil)
      |> assign(:connected, false)
      |> assign(:error, nil)
      |> assign(:cols, 80)
      |> assign(:rows, 24)
      |> assign(:show_commands, false)
      |> assign(:command_search, "")
      |> assign(:selected_category, "all")
      |> assign(:all_commands, @default_commands)

    {:ok, socket}
  end

  @impl true
  def handle_event("terminal_ready", _params, socket) do
    socket = start_terminal_session(socket)
    {:noreply, socket}
  end

  def handle_event("terminal_data", %{"data" => data}, socket) when is_binary(data) do
    pid = socket.assigns.session_pid

    if pid && Process.alive?(pid) do
      PTYSession.send_input(pid, data)
    end

    {:noreply, socket}
  end

  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket)
      when is_integer(cols) and is_integer(rows) do
    pid = socket.assigns.session_pid

    if pid && Process.alive?(pid) do
      PTYSession.resize(pid, cols, rows)
    end

    {:noreply, assign(socket, cols: cols, rows: rows)}
  end

  def handle_event("request_paste", _params, socket) do
    {:noreply, push_event(socket, "terminal_paste", %{})}
  end

  def handle_event("toggle_commands", _params, socket) do
    {:noreply, assign(socket, :show_commands, !socket.assigns.show_commands)}
  end

  def handle_event("search_commands", %{"query" => query}, socket) do
    {:noreply, assign(socket, :command_search, query)}
  end

  def handle_event("select_category", %{"cat" => cat}, socket) do
    {:noreply, assign(socket, :selected_category, cat)}
  end

  def handle_event("run_command", %{"cmd" => cmd}, socket) do
    pid = socket.assigns.session_pid

    if pid && Process.alive?(pid) do
      PTYSession.send_input(pid, cmd <> "\n")
    end

    {:noreply, push_event(socket, "terminal_insert_command", %{command: cmd, execute: true})}
  end

  def handle_event("insert_command", %{"cmd" => cmd}, socket) do
    pid = socket.assigns.session_pid

    if pid && Process.alive?(pid) do
      PTYSession.send_input(pid, cmd)
    end

    {:noreply, push_event(socket, "terminal_insert_command", %{command: cmd, execute: false})}
  end

  def handle_event("switch_to_zsh", _params, socket) do
    pid = socket.assigns.session_pid

    if pid && Process.alive?(pid) do
      PTYSession.send_input(pid, "exec zsh -l\n")
    end

    {:noreply, socket}
  end

  def handle_event("clear_screen", _params, socket) do
    pid = socket.assigns.session_pid

    if pid && Process.alive?(pid) do
      PTYSession.send_input(pid, "\x0c")
    end

    {:noreply, push_event(socket, "terminal_clear", %{})}
  end

  def handle_event("font_increase", _params, socket) do
    {:noreply, push_event(socket, "terminal_font_change", %{delta: 1})}
  end

  def handle_event("font_decrease", _params, socket) do
    {:noreply, push_event(socket, "terminal_font_change", %{delta: -1})}
  end

  def handle_event("reconnect", _params, socket) do
    if pid = socket.assigns.session_pid do
      if Process.alive?(pid), do: PTYSession.close(pid)
    end

    socket =
      socket
      |> assign(session_pid: nil, connected: false, error: nil)
      |> push_event("terminal_output", %{
        data: "\r\n\x1b[1;34m[ssh-client]\x1b[0m \x1b[2mReconnecting to #{socket.assigns.server_id}...\x1b[0m\r\n"
      })
      |> start_terminal_session()

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Messages from PTYSession
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:pty_connected, pid}, socket) do
    ActivityLog.info(socket.assigns.server_id, "Interactive terminal shell ready")

    socket =
      socket
      |> assign(connected: true, session_pid: pid, error: nil)
      |> push_event("terminal_output", %{
        data: "\x1b[1;32m\u2713 Connected to #{socket.assigns.server_id}\x1b[0m\r\n\r\n"
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_data, _pid, data}, socket) do
    {:noreply, push_event(socket, "terminal_output", %{data: data})}
  end

  @impl true
  def handle_info({:pty_error, reason}, socket) do
    err_str = format_error_reason(reason)
    ActivityLog.error(socket.assigns.server_id, "PTY Error: #{err_str}", reason)

    ansi_msg =
      "\r\n\x1b[1;31m[SSH Connection Error]\x1b[0m #{err_str}\r\n" <>
        "\x1b[2mCheck server host, port, credentials, or see the \x1b[1;34mLogs\x1b[0m\x1b[2m tab for full details.\x1b[0m\r\n"

    socket =
      socket
      |> assign(connected: false, error: err_str)
      |> push_event("terminal_output", %{data: ansi_msg})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_eof, _pid}, socket) do
    {:noreply,
     push_event(socket, "terminal_output", %{
       data: "\r\n\x1b[2m[Remote shell sent EOF]\x1b[0m\r\n"
     })}
  end

  @impl true
  def handle_info({:pty_exit, _pid, exit_code}, socket) do
    {:noreply,
     socket
     |> assign(connected: false)
     |> push_event("terminal_output", %{
       data: "\r\n\x1b[2m[Process exited with status #{exit_code}]\x1b[0m\r\n"
     })}
  end

  @impl true
  def handle_info({:pty_closed, _pid}, socket) do
    {:noreply,
     socket
     |> assign(connected: false)
     |> push_event("terminal_output", %{
       data: "\r\n\x1b[2m[Connection closed by remote host]\x1b[0m\r\n"
     })}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:session_pid] do
      if Process.alive?(pid) do
        PTYSession.close(pid)
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    filtered_commands = filter_commands(assigns.all_commands, assigns.selected_category, assigns.command_search)
    assigns = assign(assigns, :filtered_commands, filtered_commands)

    ~H"""
    <div class="flex flex-col h-screen w-screen bg-[#050505] overflow-hidden select-none">
      <!-- Terminal topbar -->
      <div class="h-11 flex items-center justify-between px-3 bg-[#0a0a0a] border-b border-[#1f1f1f] shrink-0 z-20">
        <!-- Left: Host back nav & Server ID -->
        <div class="flex items-center gap-2.5 min-w-0">
          <a
            href="/"
            class="text-zinc-400 hover:text-white text-xs font-mono transition-colors inline-flex items-center gap-1 px-2.5 py-1 rounded bg-[#141414] hover:bg-[#202020] border border-[#27272a] shrink-0"
            title="Back to Hosts"
          >
            &larr; <span class="hidden sm:inline">Hosts</span>
          </a>
          <span class="text-zinc-700">|</span>
          <span class="text-white text-xs font-mono font-semibold truncate"><%= @server_id %></span>
          <%= if @server do %>
            <span class="text-zinc-500 text-[11px] font-mono hidden md:inline truncate"><%= @server.user %>@<%= @server.host %>:<%= @server.port || 22 %></span>
          <% end %>
        </div>

        <!-- Center / Right: Quick Controls & Status -->
        <div class="flex items-center gap-2">
          <!-- Connection badge -->
          <span class={["inline-flex items-center gap-1.5 text-[11px] font-mono px-2 py-0.5 rounded-full border shrink-0",
            if(@connected, do: "bg-emerald-500/10 text-emerald-400 border-emerald-500/20", else: if(@error, do: "bg-red-500/10 text-red-400 border-red-500/20", else: "bg-blue-500/10 text-blue-400 border-blue-500/20"))]}>
            <span class={["w-1.5 h-1.5 rounded-full",
              if(@connected, do: "bg-emerald-400 animate-pulse", else: if(@error, do: "bg-red-400", else: "bg-blue-400 animate-ping"))]}></span>
            <span class="hidden sm:inline"><%= if @connected, do: "connected", else: if(@error, do: "disconnected", else: "connecting...") %></span>
          </span>

          <span class="text-zinc-600 text-[10px] font-mono hidden lg:inline"><%= @cols %>x<%= @rows %></span>

          <!-- Quick Action: Paste -->
          <button
            phx-click="request_paste"
            class="h-7 px-2.5 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-300 hover:text-white text-xs rounded-md transition-colors font-mono inline-flex items-center gap-1"
            title="Paste Clipboard (Ctrl+V)"
          >
            <span>📋</span> <span class="hidden sm:inline">Paste</span>
          </button>

          <!-- Quick Action: Toggle Commands Drawer -->
          <button
            phx-click="toggle_commands"
            class={["h-7 px-2.5 border text-xs rounded-md transition-colors font-mono inline-flex items-center gap-1.5",
              if(@show_commands, do: "bg-blue-600/20 border-blue-500 text-blue-300", else: "bg-[#141414] hover:bg-[#202020] border-[#27272a] hover:border-zinc-500 text-zinc-300 hover:text-white")]}
            title="Toggle Command Autocomplete & Suggestions"
          >
            <span>⚡</span> <span class="hidden sm:inline">Commands</span>
          </button>

          <!-- Quick Action: Switch to Zsh -->
          <button
            phx-click="switch_to_zsh"
            class="h-7 px-2 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-blue-500/60 text-blue-400 hover:text-blue-300 text-xs rounded-md transition-colors font-mono inline-flex items-center gap-1"
            title="Switch remote shell to Zsh (exec zsh -l)"
          >
            <span>🐚</span> <span class="hidden md:inline">Zsh</span>
          </button>

          <!-- Quick Action: Clear Screen -->
          <button
            phx-click="clear_screen"
            class="h-7 px-2 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-400 hover:text-zinc-200 text-xs rounded-md transition-colors font-mono"
            title="Clear Terminal Screen (Ctrl+L)"
          >
            🧹
          </button>

          <!-- Font Size Adjusters -->
          <div class="hidden sm:flex items-center border border-[#27272a] rounded-md bg-[#141414] overflow-hidden">
            <button
              phx-click="font_decrease"
              class="h-7 px-2 text-[11px] text-zinc-400 hover:text-white hover:bg-[#222] transition-colors font-mono"
              title="Decrease Font Size (Ctrl -)"
            >
              A-
            </button>
            <span class="w-[1px] h-4 bg-[#27272a]"></span>
            <button
              phx-click="font_increase"
              class="h-7 px-2 text-[11px] text-zinc-400 hover:text-white hover:bg-[#222] transition-colors font-mono"
              title="Increase Font Size (Ctrl +)"
            >
              A+
            </button>
          </div>

          <!-- Reconnect -->
          <button
            phx-click="reconnect"
            class="h-7 px-2 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-300 hover:text-white text-xs rounded-md transition-colors font-mono"
            title="Reconnect Session"
          >
            🔄
          </button>

          <!-- Logs -->
          <a
            href="/logs"
            class="h-7 px-2.5 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-400 hover:text-zinc-200 text-xs rounded-md transition-colors font-mono inline-flex items-center"
            title="View Real-Time Logs"
          >
            Logs
          </a>
        </div>
      </div>

      <!-- Main Body: Terminal + Docked Command Palette -->
      <div class="flex-1 flex flex-col min-h-0 w-full relative bg-[#050505]">
        <!-- xterm.js full-height container -->
        <div
          id="xterm-container"
          phx-hook="TerminalHook"
          phx-update="ignore"
          class="flex-1 w-full h-full min-h-0 overflow-hidden"
          data-server-id={@server_id}
          data-cols={@cols}
          data-rows={@rows}
        ></div>

        <!-- Slide-out / Docked Command Autocomplete & Suggestions Drawer -->
        <%= if @show_commands do %>
          <div class="absolute bottom-0 inset-x-0 bg-[#0c0c0e]/95 border-t border-[#27272a] backdrop-blur-md shadow-2xl z-30 flex flex-col max-h-[48vh] transition-all animate-in fade-in slide-in-from-bottom duration-150">
            <!-- Header & Search Bar -->
            <div class="p-2.5 px-4 border-b border-[#1f1f1f] flex items-center justify-between gap-3 bg-[#111113]">
              <div class="flex items-center gap-2 flex-1 max-w-md">
                <span class="text-zinc-500 text-xs">⚡</span>
                <input
                  type="text"
                  placeholder="Type to filter command suggestions or execute..."
                  value={@command_search}
                  phx-keyup="search_commands"
                  phx-debounce="100"
                  name="query"
                  class="w-full bg-[#18181b] border border-[#27272a] rounded px-2.5 py-1 text-xs font-mono text-zinc-200 focus:outline-none focus:border-blue-500"
                  autofocus
                />
              </div>

              <!-- Category Pills -->
              <div class="hidden md:flex items-center gap-1 text-[11px] font-mono">
                <button
                  phx-click="select_category"
                  phx-value-cat="all"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "all", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  All
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="zsh"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "zsh", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  🐚 Zsh
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="sys"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "sys", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  💻 System
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="docker"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "docker", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  🐳 Docker
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="services"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "services", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  ⚙️ Services
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="net"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "net", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  🌐 Network
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="files"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "files", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  📁 Files
                </button>
              </div>

              <!-- Close Button -->
              <button
                phx-click="toggle_commands"
                class="text-zinc-500 hover:text-zinc-200 text-xs px-2 py-1 rounded hover:bg-[#202020] transition-colors font-mono"
              >
                ✕ Close
              </button>
            </div>

            <!-- Suggestions Grid -->
            <div class="p-3 overflow-y-auto max-h-[36vh] grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
              <%= for item <- @filtered_commands do %>
                <div class="p-2.5 rounded-lg bg-[#141416] border border-[#222226] hover:border-blue-500/50 hover:bg-[#19191d] transition-all flex flex-col justify-between group">
                  <div>
                    <div class="flex items-center justify-between gap-2 mb-1">
                      <span class="text-xs font-medium text-zinc-200 font-mono"><%= item.label %></span>
                      <span class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-[#202024] text-zinc-400 font-mono"><%= item.cat %></span>
                    </div>
                    <p class="text-[11px] text-zinc-500 leading-tight mb-2"><%= item.desc %></p>
                    <code class="text-[11px] font-mono text-blue-400 bg-[#09090b] px-2 py-1 rounded block truncate border border-[#1b1b1f] select-text">
                      <%= item.cmd %>
                    </code>
                  </div>

                  <div class="mt-2.5 flex items-center justify-end gap-1.5 pt-2 border-t border-[#1f1f23]">
                    <button
                      phx-click="insert_command"
                      phx-value-cmd={item.cmd}
                      class="px-2 py-1 rounded bg-[#202024] hover:bg-[#2c2c32] text-zinc-300 hover:text-white text-[10px] font-mono transition-colors"
                      title="Insert command into prompt without executing"
                    >
                      Insert
                    </button>
                    <button
                      phx-click="run_command"
                      phx-value-cmd={item.cmd}
                      class="px-2.5 py-1 rounded bg-blue-600 hover:bg-blue-500 text-white text-[10px] font-mono font-medium transition-colors shadow-sm inline-flex items-center gap-1"
                      title="Run immediately in terminal"
                    >
                      ▶ Run
                    </button>
                  </div>
                </div>
              <% end %>
              <%= if Enum.empty?(@filtered_commands) do %>
                <div class="col-span-full py-8 text-center text-zinc-500 text-xs font-mono">
                  No command suggestions match "<%= @command_search %>"
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp filter_commands(commands, category, search_query) do
    q = String.trim(String.downcase(search_query || ""))

    commands
    |> Enum.filter(fn item ->
      cat_match = category == "all" || item.cat == category

      search_match =
        if q == "" do
          true
        else
          String.contains?(String.downcase(item.cmd), q) or
            String.contains?(String.downcase(item.label), q) or
            String.contains?(String.downcase(item.desc), q)
        end

      cat_match and search_match
    end)
  end

  defp start_terminal_session(socket) do
    case socket.assigns.server do
      %Server{} = server ->
        opts = [
          client_pid: self(),
          cols: socket.assigns.cols,
          rows: socket.assigns.rows
        ]

        case TerminalSupervisor.start_session(server, opts) do
          {:ok, pid} ->
            assign(socket, session_pid: pid, error: nil)

          {:error, reason} ->
            err_str = "Failed to start terminal supervisor child: #{inspect(reason)}"
            ActivityLog.error(socket.assigns.server_id, err_str, reason)

            socket
            |> assign(connected: false, error: err_str)
            |> push_event("terminal_output", %{
              data: "\r\n\x1b[1;31m[Error]\x1b[0m #{err_str}\r\n"
            })
        end

      nil ->
        err_str = "Host '#{socket.assigns.server_id}' not found in configuration."
        ActivityLog.error(socket.assigns.server_id, err_str)

        socket
        |> assign(connected: false, error: err_str)
        |> push_event("terminal_output", %{
          data: "\r\n\x1b[1;31m[Configuration Error]\x1b[0m #{err_str}\r\n"
        })
    end
  end

  defp resolve_server_struct(server_id) do
    case ServerManager.get_server(server_id) do
      {:ok, snapshot} when is_map(snapshot) ->
        %Server{
          id: snapshot.id,
          name: snapshot.name || snapshot.id,
          host: snapshot.host,
          user: snapshot.user,
          port: snapshot.port || 22,
          proxy_jump: snapshot.proxy_jump
        }

      _ ->
        # Try loading directly from config file
        case Config.load_file(Config.default_config_path()) do
          {:ok, %Config{servers: servers}} ->
            Enum.find(servers, fn s -> s.id == server_id end)

          _ ->
            nil
        end
    end
  end

  defp format_error_reason({:connection_failed, reason}), do: "Connection failed: #{format_error_reason(reason)}"
  defp format_error_reason({:connect_failed, reason}), do: "Connect failed: #{format_error_reason(reason)}"
  defp format_error_reason({:pty_failed, reason}), do: "PTY allocation failed: #{format_error_reason(reason)}"
  defp format_error_reason(:econnrefused), do: "Connection refused (econnrefused) - check host & port 22"
  defp format_error_reason(:etimedout), do: "Connection timed out (etimedout)"
  defp format_error_reason(:nxdomain), do: "Host domain name cannot be resolved (nxdomain)"
  defp format_error_reason(:key_exchange_failed), do: "Key exchange / host key verification failed"
  defp format_error_reason(:auth_failed), do: "Authentication failed - public key or password rejected"
  defp format_error_reason('Host key not accepted'), do: "Host key not accepted"
  defp format_error_reason(str) when is_binary(str), do: str
  defp format_error_reason(other), do: inspect(other)
end
