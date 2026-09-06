defmodule SSHClientWeb.TerminalLive do
  @moduledoc """
  Phoenix LiveView hosting the interactive xterm.js embedded terminal with
  multi-tab session management, PTY supervisor integration, bidirectional I/O,
  and quick command autocomplete.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}

  alias SSHClient.ActivityLog
  alias SSHClient.Config
  alias SSHClient.Config.Server
  alias SSHClient.ServerManager
  alias SSHClient.SSH.PTYSession
  alias SSHClient.TerminalSupervisor
  alias SSHClient.Vault

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
    if not Vault.unlocked?() do
      {:ok, push_navigate(socket, to: "/lock")}
    else
      server = resolve_server_struct(server_id)

      initial_tab = %{
        id: 1,
        title: "Shell 1",
        session_pid: nil,
        connected: false,
        error: nil
      }

      socket =
        socket
        |> assign(:page_title, "Terminal — #{server_id}")
        |> assign(:server_id, server_id)
        |> assign(:server, server)
        |> assign(:tabs, [initial_tab])
        |> assign(:active_tab_id, 1)
        |> assign(:next_tab_id, 2)
        |> assign(:cols, 80)
        |> assign(:rows, 24)
        |> assign(:show_commands, false)
        |> assign(:command_search, "")
        |> assign(:selected_category, "all")
        |> assign(:all_commands, @default_commands)
        |> assign(:target_user, nil)
        |> assign(:target_auth, nil)

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = params["user"]
    auth = params["auth"]

    socket =
      socket
      |> assign(:target_user, if(user && user != "", do: user, else: nil))
      |> assign(:target_auth, if(auth && auth != "", do: auth, else: nil))

    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal_ready", _params, socket) do
    tab = active_tab(socket)
    socket =
      if is_nil(tab.session_pid) do
        start_tab_session(socket, tab.id)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("terminal_data", %{"data" => data}, socket) when is_binary(data) do
    tab = active_tab(socket)

    if tab && tab.session_pid && Process.alive?(tab.session_pid) do
      PTYSession.send_input(tab.session_pid, data)
    end

    {:noreply, socket}
  end

  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket)
      when is_integer(cols) and is_integer(rows) do
    socket = assign(socket, cols: cols, rows: rows)

    Enum.each(socket.assigns.tabs, fn t ->
      if t.session_pid && Process.alive?(t.session_pid) do
        PTYSession.resize(t.session_pid, cols, rows)
      end
    end)

    {:noreply, socket}
  end

  def handle_event("switch_tab", %{"id" => id_str}, socket) do
    tab_id =
      case Integer.parse(to_string(id_str)) do
        {id, ""} -> id
        _ -> socket.assigns.active_tab_id
      end

    new_tab = Enum.find(socket.assigns.tabs, fn t -> t.id == tab_id end)

    if new_tab do
      socket =
        socket
        |> assign(:active_tab_id, tab_id)
        |> push_event("terminal_clear", %{})
        |> push_event("terminal_output", %{
          data: "\r\n\x1b[1;34m[ssh-client]\x1b[0m Switched to \x1b[1;37m#{new_tab.title}\x1b[0m\r\n"
        })

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_tab", _params, socket) do
    new_id = socket.assigns.next_tab_id
    new_tab = %{
      id: new_id,
      title: "Shell #{new_id}",
      session_pid: nil,
      connected: false,
      error: nil
    }

    socket =
      socket
      |> assign(:tabs, socket.assigns.tabs ++ [new_tab])
      |> assign(:active_tab_id, new_id)
      |> assign(:next_tab_id, new_id + 1)
      |> push_event("terminal_clear", %{})
      |> push_event("terminal_output", %{
        data: "\r\n\x1b[1;34m[ssh-client]\x1b[0m Opening new session: \x1b[1;37m#{new_tab.title}\x1b[0m...\r\n"
      })
      |> start_tab_session(new_id)

    {:noreply, socket}
  end

  def handle_event("close_tab", %{"id" => id_str}, socket) do
    tab_id =
      case Integer.parse(to_string(id_str)) do
        {id, ""} -> id
        _ -> nil
      end

    if tab_id && length(socket.assigns.tabs) > 1 do
      target_tab = Enum.find(socket.assigns.tabs, fn t -> t.id == tab_id end)
      if target_tab && target_tab.session_pid && Process.alive?(target_tab.session_pid) do
        PTYSession.close(target_tab.session_pid)
      end

      remaining = Enum.reject(socket.assigns.tabs, fn t -> t.id == tab_id end)
      new_active =
        if socket.assigns.active_tab_id == tab_id do
          hd(remaining).id
        else
          socket.assigns.active_tab_id
        end

      active_struct = Enum.find(remaining, fn t -> t.id == new_active end)

      socket =
        socket
        |> assign(tabs: remaining, active_tab_id: new_active)
        |> push_event("terminal_clear", %{})
        |> push_event("terminal_output", %{
          data: "\r\n\x1b[1;34m[ssh-client]\x1b[0m Switched to \x1b[1;37m#{active_struct.title}\x1b[0m\r\n"
        })

      {:noreply, socket}
    else
      {:noreply, socket}
    end
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
    tab = active_tab(socket)

    if tab && tab.session_pid && Process.alive?(tab.session_pid) do
      PTYSession.send_input(tab.session_pid, cmd <> "\n")
    end

    {:noreply, push_event(socket, "terminal_insert_command", %{command: cmd, execute: true})}
  end

  def handle_event("insert_command", %{"cmd" => cmd}, socket) do
    tab = active_tab(socket)

    if tab && tab.session_pid && Process.alive?(tab.session_pid) do
      PTYSession.send_input(tab.session_pid, cmd)
    end

    {:noreply, push_event(socket, "terminal_insert_command", %{command: cmd, execute: false})}
  end

  def handle_event("switch_to_zsh", _params, socket) do
    tab = active_tab(socket)

    if tab && tab.session_pid && Process.alive?(tab.session_pid) do
      PTYSession.send_input(tab.session_pid, "exec zsh -l\n")
    end

    {:noreply, socket}
  end

  def handle_event("clear_screen", _params, socket) do
    tab = active_tab(socket)

    if tab && tab.session_pid && Process.alive?(tab.session_pid) do
      PTYSession.send_input(tab.session_pid, "\x0c")
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
    tab = active_tab(socket)

    if tab && tab.session_pid && Process.alive?(tab.session_pid) do
      PTYSession.close(tab.session_pid)
    end

    socket =
      socket
      |> update_tab(tab.id, fn t -> %{t | session_pid: nil, connected: false, error: nil} end)
      |> push_event("terminal_output", %{
        data: "\r\n\x1b[1;34m[ssh-client]\x1b[0m Reconnecting #{tab.title} to #{socket.assigns.server_id}...\r\n"
      })
      |> start_tab_session(tab.id)

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Messages from PTYSession
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:pty_connected, pid}, socket) do
    ActivityLog.info(socket.assigns.server_id, "Interactive terminal shell ready")

    socket =
      update_tab_by_pid(socket, pid, fn t -> %{t | connected: true, error: nil} end)

    tab = active_tab(socket)
    if tab && tab.session_pid == pid do
      {:noreply, push_event(socket, "terminal_output", %{
        data: "\x1b[1;32mConnected to #{socket.assigns.server_id} (#{tab.title})\x1b[0m\r\n\r\n"
      })}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:pty_data, pid, data}, socket) do
    tab = active_tab(socket)
    if tab && tab.session_pid == pid do
      {:noreply, push_event(socket, "terminal_output", %{data: data})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:pty_error, reason}, socket) do
    err_str = format_error_reason(reason)
    ActivityLog.error(socket.assigns.server_id, "PTY Error: #{err_str}", reason)

    tab = active_tab(socket)
    socket =
      if tab do
        update_tab(socket, tab.id, fn t -> %{t | connected: false, error: err_str} end)
      else
        socket
      end

    ansi_msg =
      "\r\n\x1b[1;31m[SSH Connection Error]\x1b[0m #{err_str}\r\n" <>
        "\x1b[2mCheck server host, port, credentials, or see the \x1b[1;34mLogs\x1b[0m\x1b[2m tab for details.\x1b[0m\r\n"

    {:noreply, push_event(socket, "terminal_output", %{data: ansi_msg})}
  end

  @impl true
  def handle_info({:pty_eof, pid}, socket) do
    tab = active_tab(socket)
    if tab && tab.session_pid == pid do
      {:noreply, push_event(socket, "terminal_output", %{
        data: "\r\n\x1b[2m[Remote shell sent EOF]\x1b[0m\r\n"
      })}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:pty_exit, pid, exit_code}, socket) do
    socket = update_tab_by_pid(socket, pid, fn t -> %{t | connected: false} end)
    tab = active_tab(socket)
    if tab && tab.session_pid == pid do
      {:noreply, push_event(socket, "terminal_output", %{
        data: "\r\n\x1b[2m[Process exited with status #{exit_code}]\x1b[0m\r\n"
      })}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:pty_closed, pid}, socket) do
    socket = update_tab_by_pid(socket, pid, fn t -> %{t | connected: false} end)
    tab = active_tab(socket)
    if tab && tab.session_pid == pid do
      {:noreply, push_event(socket, "terminal_output", %{
        data: "\r\n\x1b[2m[Connection closed by remote host]\x1b[0m\r\n"
      })}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    Enum.each(socket.assigns.tabs, fn t ->
      if t.session_pid && Process.alive?(t.session_pid) do
        PTYSession.close(t.session_pid)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    filtered_commands = filter_commands(assigns.all_commands, assigns.selected_category, assigns.command_search)
    assigns = assign(assigns, :filtered_commands, filtered_commands)
    cur_tab = Enum.find(assigns.tabs, fn t -> t.id == assigns.active_tab_id end) || hd(assigns.tabs)
    assigns = assign(assigns, :cur_tab, cur_tab)

    ~H"""
    <div class="flex flex-col h-screen w-screen bg-[#050505] overflow-hidden select-none font-sans">
      <!-- Terminal topbar -->
      <div class="h-11 flex items-center justify-between px-3 bg-[#0a0a0a] border-b border-[#1f1f1f] shrink-0 z-20">
        <!-- Left: Host back nav, Server ID, BETA badge, Multi-tab bar -->
        <div class="flex items-center gap-2 min-w-0">
          <a
            href="/"
            class="text-zinc-400 hover:text-white text-xs font-mono transition-colors inline-flex items-center gap-1 px-2.5 py-1 rounded bg-[#141414] hover:bg-[#202020] border border-[#27272a] shrink-0"
            title="Back to Hosts"
          >
            &larr; <span class="hidden sm:inline">Hosts</span>
          </a>
          <span class="text-zinc-700">|</span>
          <span class="text-white text-xs font-mono font-semibold truncate"><%= @server_id %></span>
          <span class="px-1.5 py-0.5 text-[9px] font-mono font-semibold uppercase tracking-wider rounded bg-red-500/10 text-red-400 border border-red-500/20">BETA</span>

          <!-- Multi-Tab workspace pills -->
          <div class="hidden sm:flex items-center gap-1 pl-1.5 border-l border-[#27272a]">
            <%= for tab <- @tabs do %>
              <div class={["flex items-center rounded font-mono text-xs overflow-hidden border transition-colors",
                if(tab.id == @active_tab_id, do: "bg-[#18181b] border-blue-500/60 text-blue-400", else: "bg-[#0e0e10] border-[#222226] text-zinc-500 hover:text-zinc-300 hover:bg-[#141416]")]}>
                <button
                  phx-click="switch_tab"
                  phx-value-id={tab.id}
                  class="px-2 py-0.5 text-left flex items-center gap-1.5"
                >
                  <span class={["w-1.5 h-1.5 rounded-full", if(tab.connected, do: "bg-emerald-400", else: "bg-zinc-600")]}></span>
                  <span><%= tab.title %></span>
                </button>
                <%= if length(@tabs) > 1 do %>
                  <button
                    phx-click="close_tab"
                    phx-value-id={tab.id}
                    class="px-1 py-0.5 text-zinc-600 hover:text-red-400 hover:bg-white/5 transition-colors"
                    title="Close Tab"
                  >
                    &times;
                  </button>
                <% end %>
              </div>
            <% end %>
            <button
              phx-click="new_tab"
              class="h-5 px-1.5 bg-[#121214] hover:bg-[#202020] border border-[#222226] hover:border-zinc-500 text-zinc-400 hover:text-white rounded text-[11px] font-mono transition-colors"
              title="Open New Terminal Tab"
            >
              +
            </button>
          </div>
        </div>

        <!-- Center / Right: Quick Controls & Status -->
        <div class="flex items-center gap-2">
          <!-- Connection badge for active tab -->
          <span class={["inline-flex items-center gap-1.5 text-[11px] font-mono px-2 py-0.5 rounded-full border shrink-0",
            if(@cur_tab.connected, do: "bg-emerald-500/10 text-emerald-400 border-emerald-500/20", else: if(@cur_tab.error, do: "bg-red-500/10 text-red-400 border-red-500/20", else: "bg-blue-500/10 text-blue-400 border-blue-500/20"))]}>
            <span class={["w-1.5 h-1.5 rounded-full",
              if(@cur_tab.connected, do: "bg-emerald-400 animate-pulse", else: if(@cur_tab.error, do: "bg-red-400", else: "bg-blue-400 animate-ping"))]}></span>
            <span class="hidden md:inline"><%= if @cur_tab.connected, do: "connected", else: if(@cur_tab.error, do: "error", else: "connecting...") %></span>
          </span>

          <span class="text-zinc-600 text-[10px] font-mono hidden lg:inline"><%= @cols %>x<%= @rows %></span>

          <!-- SFTP Quick Link -->
          <a
            href={"/sftp/#{@server_id}"}
            class="h-7 px-2.5 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-300 hover:text-white text-xs rounded-md transition-colors font-mono inline-flex items-center"
            title="Open SFTP File Explorer"
          >
            SFTP
          </a>

          <!-- Quick Action: Paste -->
          <button
            phx-click="request_paste"
            class="h-7 px-2.5 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-300 hover:text-white text-xs rounded-md transition-colors font-mono inline-flex items-center"
            title="Paste Clipboard (Ctrl+V)"
          >
            Paste
          </button>

          <!-- Quick Action: Toggle Commands Drawer -->
          <button
            phx-click="toggle_commands"
            class={["h-7 px-2.5 border text-xs rounded-md transition-colors font-mono inline-flex items-center",
              if(@show_commands, do: "bg-blue-600/20 border-blue-500 text-blue-300", else: "bg-[#141414] hover:bg-[#202020] border-[#27272a] hover:border-zinc-500 text-zinc-300 hover:text-white")]}
            title="Toggle Command Autocomplete & Suggestions"
          >
            Cmds
          </button>

          <!-- Quick Action: Switch to Zsh -->
          <button
            phx-click="switch_to_zsh"
            class="h-7 px-2.5 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-blue-500/60 text-blue-400 hover:text-blue-300 text-xs rounded-md transition-colors font-mono inline-flex items-center"
            title="Switch remote shell to Zsh (exec zsh -l)"
          >
            Zsh
          </button>

          <!-- Quick Action: Clear Screen -->
          <button
            phx-click="clear_screen"
            class="h-7 px-2 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-400 hover:text-zinc-200 text-xs rounded-md transition-colors font-mono"
            title="Clear Terminal Screen (Ctrl+L)"
          >
            Clear
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
            class="h-7 px-2.5 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-300 hover:text-white text-xs rounded-md transition-colors font-mono"
            title="Reconnect Session"
          >
            Reconnect
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
                <span class="text-zinc-500 text-xs font-mono">&gt;</span>
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
                  Zsh
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="sys"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "sys", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  System
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="docker"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "docker", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  Docker
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="services"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "services", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  Services
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="net"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "net", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  Network
                </button>
                <button
                  phx-click="select_category"
                  phx-value-cat="files"
                  class={["px-2 py-0.5 rounded transition-colors", if(@selected_category == "files", do: "bg-blue-600 text-white font-medium", else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]")]}
                >
                  Files
                </button>
              </div>

              <!-- Close Button -->
              <button
                phx-click="toggle_commands"
                class="text-zinc-500 hover:text-zinc-200 text-xs px-2 py-1 rounded hover:bg-[#202020] transition-colors font-mono"
              >
                Close
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
                      class="px-2.5 py-1 rounded bg-blue-600 hover:bg-blue-500 text-white text-[10px] font-mono font-medium transition-colors shadow-sm inline-flex items-center"
                      title="Run immediately in terminal"
                    >
                      Run
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

  defp active_tab(socket) do
    Enum.find(socket.assigns.tabs, fn t -> t.id == socket.assigns.active_tab_id end) || hd(socket.assigns.tabs)
  end

  defp update_tab(socket, tab_id, fun) when is_function(fun, 1) do
    new_tabs =
      Enum.map(socket.assigns.tabs, fn t ->
        if t.id == tab_id, do: fun.(t), else: t
      end)

    assign(socket, :tabs, new_tabs)
  end

  defp update_tab_by_pid(socket, pid, fun) when is_function(fun, 1) do
    new_tabs =
      Enum.map(socket.assigns.tabs, fn t ->
        if t.session_pid == pid, do: fun.(t), else: t
      end)

    assign(socket, :tabs, new_tabs)
  end

  defp start_tab_session(socket, tab_id) do
    case socket.assigns.server do
      %Server{} = server ->
        opts = [
          client_pid: self(),
          cols: socket.assigns.cols,
          rows: socket.assigns.rows
        ]

        opts =
          if socket.assigns[:target_user] && socket.assigns[:target_user] != "" do
            Keyword.put(opts, :user, socket.assigns[:target_user])
          else
            opts
          end

        opts =
          if socket.assigns[:target_auth] && socket.assigns[:target_auth] != "" do
            auth_atom = if socket.assigns[:target_auth] in ["password", :password], do: :password, else: :key
            Keyword.put(opts, :auth_method, auth_atom)
          else
            opts
          end

        case TerminalSupervisor.start_session(server, opts) do
          {:ok, pid} ->
            update_tab(socket, tab_id, fn t -> %{t | session_pid: pid, error: nil} end)

          {:error, reason} ->
            err_str = "Failed to start terminal session: #{inspect(reason)}"
            ActivityLog.error(socket.assigns.server_id, err_str, reason)

            socket
            |> update_tab(tab_id, fn t -> %{t | connected: false, error: err_str} end)
            |> push_event("terminal_output", %{
              data: "\r\n\x1b[1;31m[Error]\x1b[0m #{err_str}\r\n"
            })
        end

      nil ->
        err_str = "Host '#{socket.assigns.server_id}' not found in configuration."
        ActivityLog.error(socket.assigns.server_id, err_str)

        socket
        |> update_tab(tab_id, fn t -> %{t | connected: false, error: err_str} end)
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
          users: Map.get(snapshot, :users, []),
          default_auth_method: Map.get(snapshot, :default_auth_method, :key),
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
  defp format_error_reason(~c"Host key not accepted"), do: "Host key not accepted"
  defp format_error_reason(str) when is_binary(str), do: str
  defp format_error_reason(other), do: inspect(other)
end
