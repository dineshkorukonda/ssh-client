defmodule SSHClientWeb.TerminalLive do
  @moduledoc """
  Phoenix LiveView hosting the interactive xterm.js embedded terminal with
  multi-tab session management, PTY supervisor integration, bidirectional I/O,
  and quick command autocomplete.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}

  import SSHClientWeb.CoreComponents

  alias SSHClient.ActivityLog
  alias SSHClient.CommandPalette
  alias SSHClient.Config
  alias SSHClient.Config.Server
  alias SSHClient.ServerManager
  alias SSHClient.SSH.ConfigImporter
  alias SSHClient.SSH.HostKeyVerifier
  alias SSHClient.SessionManager
  alias SSHClient.SessionWorker
  alias SSHClient.Store
  alias SSHClient.Terminal.Layout
  alias SSHClient.Vault

  @default_commands [
    # Zsh & Shell
    %{
      cmd: "exec zsh -l",
      label: "Switch to Zsh Shell",
      desc: "Launches interactive login Zsh session",
      cat: "zsh"
    },
    %{
      cmd: "source ~/.zshrc",
      label: "Reload Zsh Config",
      desc: "Re-sources ~/.zshrc profile",
      cat: "zsh"
    },
    %{
      cmd: "echo $SHELL",
      label: "Check Active Shell",
      desc: "Displays current default shell path",
      cat: "zsh"
    },
    %{
      cmd: "which zsh bash fish",
      label: "Find Installed Shells",
      desc: "Checks binary paths for common shells",
      cat: "zsh"
    },
    %{
      cmd: "chsh -s $(which zsh)",
      label: "Set Default Shell to Zsh",
      desc: "Changes login shell for current user",
      cat: "zsh"
    },

    # System & Hardware
    %{
      cmd: "htop",
      label: "Interactive Process Monitor (htop)",
      desc: "Interactive process and core monitor",
      cat: "sys"
    },
    %{
      cmd: "df -h",
      label: "Disk Space Usage (df -h)",
      desc: "Show available filesystem disk space",
      cat: "sys"
    },
    %{
      cmd: "free -h",
      label: "Memory Usage (free -h)",
      desc: "Display RAM & swap usage in human units",
      cat: "sys"
    },
    %{
      cmd: "uptime",
      label: "System Uptime & Load",
      desc: "Shows system uptime and 1/5/15m load average",
      cat: "sys"
    },
    %{
      cmd: "uname -a",
      label: "Kernel & Architecture",
      desc: "Outputs OS kernel release and architecture",
      cat: "sys"
    },
    %{
      cmd: "vmstat 1 5",
      label: "Virtual Memory Stats",
      desc: "Samples virtual memory, IO, and CPU activity",
      cat: "sys"
    },

    # Docker & Containers
    %{
      cmd: "docker ps -a",
      label: "List All Containers",
      desc: "Shows all running and stopped containers",
      cat: "docker"
    },
    %{
      cmd: "docker stats --no-stream",
      label: "Container Resource Stats",
      desc: "Live memory and CPU per container",
      cat: "docker"
    },
    %{
      cmd: "docker compose ps",
      label: "Compose Services Status",
      desc: "Lists all docker-compose managed services",
      cat: "docker"
    },
    %{
      cmd: "docker compose up -d",
      label: "Start Compose Stack",
      desc: "Spawns compose services in background",
      cat: "docker"
    },
    %{
      cmd: "docker compose logs -f --tail 100",
      label: "Follow Compose Logs",
      desc: "Follows last 100 log lines from services",
      cat: "docker"
    },

    # Services & Logs
    %{
      cmd: "systemctl status ssh",
      label: "SSH Service Status",
      desc: "Checks SSH daemon health and logs",
      cat: "services"
    },
    %{
      cmd: "systemctl list-units --type=service --state=running",
      label: "List Running Services",
      desc: "Lists all active systemd units",
      cat: "services"
    },
    %{
      cmd: "journalctl -xe -n 50",
      label: "Recent System Errors",
      desc: "Views last 50 error journal entries",
      cat: "services"
    },
    %{
      cmd: "tail -f /var/log/syslog",
      label: "Follow System Log",
      desc: "Real-time stream of /var/log/syslog",
      cat: "services"
    },

    # Network
    %{
      cmd: "ss -tulpn",
      label: "Listening Ports (ss)",
      desc: "Lists listening TCP/UDP sockets with PIDs",
      cat: "net"
    },
    %{
      cmd: "ip a",
      label: "IP Addresses & Interfaces",
      desc: "Shows IP addresses for all network devices",
      cat: "net"
    },
    %{
      cmd: "curl -I https://google.com",
      label: "HTTP Header Probe",
      desc: "Checks internet connectivity & DNS",
      cat: "net"
    },
    %{
      cmd: "ping -c 4 1.1.1.1",
      label: "Ping Cloudflare DNS",
      desc: "Tests latency with 4 ICMP packets",
      cat: "net"
    },
    %{
      cmd: "ufw status verbose",
      label: "Firewall Status (UFW)",
      desc: "Inspects active firewall rules and policies",
      cat: "net"
    },

    # Files & Storage
    %{
      cmd: "du -sh * | sort -h",
      label: "Directory Sizes",
      desc: "Sorts folders in current path by disk usage",
      cat: "files"
    },
    %{
      cmd: "find . -type f -size +100M",
      label: "Find Large Files (>100M)",
      desc: "Locates large files taking up disk space",
      cat: "files"
    },
    %{
      cmd: "ls -la --color=auto",
      label: "Detailed File List",
      desc: "Lists all files with permissions and owners",
      cat: "files"
    }
  ]

  @impl true
  def mount(params, _session, socket) do
    if not Vault.unlocked?() do
      {:ok, push_navigate(socket, to: "/lock")}
    else
      server_id = params["id"]
      servers = list_all_servers()
      online_count = count_online(servers)

      if is_nil(server_id) or server_id == "" do
        socket =
          socket
          |> assign(:page_title, "Terminal")
          |> assign(:server_id, nil)
          |> assign(:server, nil)
          |> assign(:servers, servers)
          |> assign(:online_count, online_count)
          |> assign(:tabs, [])
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
          |> assign(:show_deploy_modal, false)
          |> assign(:deploy_key_info, nil)
          |> assign(:deploy_status, :idle)
          |> assign(:deploy_message, nil)
          |> assign(:command_palette_open, false)
          |> assign(:command_palette_query, "")
          |> assign(:command_palette_index, 0)
          |> assign(:host_key_prompt, nil)
          |> assign(:active_pane_id, nil)

        {:ok, socket}
      else
        server = resolve_server_struct(server_id)

        initial_tab = %{
          id: 1,
          title: "Shell 1",
          layout: nil,
          session_id: nil,
          session_pid: nil,
          connected: false,
          error: nil,
          status: :disconnected
        }

        socket =
          socket
          |> assign(:page_title, "Terminal — #{server_id}")
          |> assign(:server_id, server_id)
          |> assign(:server, server)
          |> assign(:servers, servers)
          |> assign(:online_count, online_count)
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
          |> assign(:show_deploy_modal, false)
          |> assign(:deploy_key_info, nil)
          |> assign(:deploy_status, :idle)
          |> assign(:deploy_message, nil)
          |> assign(:active_pane_id, nil)
          |> assign(:host_key_prompt, nil)
          |> assign(:editing_tab_id, nil)
          |> assign(:edit_tab_title, "")
          |> assign(:command_palette_open, false)
          |> assign(:command_palette_query, "")
          |> assign(:command_palette_index, 0)
          |> assign(:restore_layout, nil)
          |> restore_or_prepare_sessions()

        if connected?(socket) do
          send(self(), :ensure_session)
        end

        {:ok, socket}
      end
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
      cond do
        is_nil(tab) ->
          socket

        tab_session_id(tab) ->
          replay_tab_buffer(socket, tab)

        true ->
          socket
          |> start_tab_session(tab.id)
          |> maybe_restore_layout_panes()
      end

    {:noreply, socket}
  end

  def handle_event("terminal_data", params, socket), do: send_pane_input(socket, params)
  def handle_event("pane_data", params, socket), do: send_pane_input(socket, params)

  def handle_event("resize", params, socket) do
    cols = parse_int(params["cols"]) || socket.assigns.cols
    rows = parse_int(params["rows"]) || socket.assigns.rows
    socket = assign(socket, cols: cols, rows: rows)

    Enum.each(socket.assigns.tabs, fn t ->
      Enum.each(tab_session_ids(t), fn session_id ->
        resize_session(session_id, cols, rows)
      end)
    end)

    {:noreply, socket}
  end

  def handle_event("pane_resize", params, socket) do
    cols = parse_int(params["cols"])
    rows = parse_int(params["rows"])
    pane_id = params["pane_id"] || socket.assigns[:active_pane_id]

    socket =
      if is_integer(cols) and is_integer(rows) do
        assign(socket, cols: cols, rows: rows)
      else
        socket
      end

    if (pane_id && is_integer(cols)) and is_integer(rows) do
      resize_session(pane_id, cols, rows)
    end

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
        |> assign(:active_pane_id, tab_session_id(new_tab))
        |> replay_tab_buffer(new_tab)
        |> persist_layout()

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
      layout: nil,
      session_id: nil,
      session_pid: nil,
      connected: false,
      error: nil,
      status: :connecting
    }

    socket =
      socket
      |> assign(:tabs, socket.assigns.tabs ++ [new_tab])
      |> assign(:active_tab_id, new_id)
      |> assign(:next_tab_id, new_id + 1)
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

      if target_tab do
        Enum.each(tab_session_ids(target_tab), fn session_id ->
          SessionManager.close_session(session_id)
          unsubscribe_session(session_id)
        end)
      end

      remaining = Enum.reject(socket.assigns.tabs, fn t -> t.id == tab_id end)

      new_active =
        if socket.assigns.active_tab_id == tab_id,
          do: hd(remaining).id,
          else: socket.assigns.active_tab_id

      active_struct = Enum.find(remaining, fn t -> t.id == new_active end)

      socket =
        socket
        |> assign(
          tabs: remaining,
          active_tab_id: new_active,
          active_pane_id: tab_session_id(active_struct)
        )
        |> replay_tab_buffer(active_struct)
        |> persist_layout()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("split_right", params, socket), do: do_split(socket, :horizontal, params)
  def handle_event("split_down", params, socket), do: do_split(socket, :vertical, params)

  def handle_event("maximize_pane", _params, socket) do
    tab = active_tab(socket)
    pane_id = socket.assigns[:active_pane_id] || tab_session_id(tab)

    if tab && pane_id && tab.layout do
      {:noreply,
       update_tab(socket, tab.id, fn t -> %{t | layout: Layout.maximize(t.layout, pane_id)} end)
       |> persist_layout()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore_panes", _params, socket) do
    tab = active_tab(socket)

    if tab && tab.layout do
      {:noreply,
       update_tab(socket, tab.id, fn t -> %{t | layout: Layout.restore(t.layout)} end)
       |> persist_layout()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("accept_host_key", _params, socket) do
    prompt = socket.assigns[:host_key_prompt]
    details = prompt && prompt[:details]

    if details do
      host = details[:host] || details["host"]
      port = details[:port] || details["port"] || 22
      key = details[:key] || details["key"]

      if prompt[:type] in [:host_key_changed, "host_key_changed"] do
        HostKeyVerifier.update_host_key(host, port, key)
      else
        HostKeyVerifier.save_host_key(host, port, key)
      end

      handle_event("reconnect", %{}, assign(socket, :host_key_prompt, nil))
    else
      {:noreply, assign(socket, :host_key_prompt, nil)}
    end
  end

  def handle_event("reject_host_key", _params, socket) do
    {:noreply, assign(socket, :host_key_prompt, nil)}
  end

  def handle_event("focus_pane", %{"pane_id" => pane_id}, socket) do
    {:noreply,
     assign(socket, :active_pane_id, pane_id)
     |> update_active_layout(&Layout.set_active(&1, pane_id))
     |> persist_layout()}
  end

  def handle_event("close_pane", params, socket) do
    tab = active_tab(socket)
    pane_id = params["pane_id"] || socket.assigns[:active_pane_id]

    cond do
      is_nil(tab) or is_nil(pane_id) ->
        {:noreply, socket}

      length(tab_session_ids(tab)) <= 1 ->
        handle_event("close_tab", %{"id" => to_string(tab.id)}, socket)

      true ->
        SessionManager.close_session(pane_id)
        unsubscribe_session(pane_id)

        new_layout = Layout.close_pane(tab.layout, pane_id)

        socket =
          socket
          |> update_tab(tab.id, fn t ->
            %{t | layout: new_layout, session_id: Layout.active_pane(new_layout)}
          end)
          |> assign(:active_pane_id, Layout.active_pane(new_layout))
          |> persist_layout()

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
    send_to_active(socket, cmd <> "\n")
    {:noreply, assign(socket, show_commands: false, command_search: "")}
  end

  def handle_event("insert_command", %{"cmd" => cmd}, socket) do
    send_to_active(socket, cmd)
    {:noreply, socket}
  end

  def handle_event("switch_to_zsh", _params, socket) do
    send_to_active(socket, "exec zsh -l\n")
    {:noreply, socket}
  end

  def handle_event("clear_screen", _params, socket) do
    send_to_active(socket, "\x0c")
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
    session_id = tab && (socket.assigns[:active_pane_id] || tab_session_id(tab))

    socket =
      if session_id do
        case SessionManager.get_session(session_id) do
          {:ok, pid} when is_pid(pid) ->
            SessionWorker.reconnect(pid)

            push_session_output(
              socket,
              session_id,
              "\r\n\x1b[1;34m[ssh-client]\x1b[0m Reconnecting...\r\n"
            )

          _ ->
            start_tab_session(socket, tab.id)
        end
      else
        start_tab_session(socket, tab && tab.id)
      end

    {:noreply, socket}
  end

  def handle_event("toggle_command_palette", _params, socket) do
    {:noreply,
     socket
     |> assign(:command_palette_open, !socket.assigns[:command_palette_open])
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
    items =
      CommandPalette.items(
        socket.assigns[:servers] || [],
        socket.assigns[:command_palette_query] || ""
      )

    idx = socket.assigns[:command_palette_index] || 0
    max_idx = max(length(items) - 1, 0)
    next = if dir == "up", do: max(idx - 1, 0), else: min(idx + 1, max_idx)
    {:noreply, assign(socket, :command_palette_index, next)}
  end

  def handle_event("run_palette_command", params, socket) do
    items =
      CommandPalette.items(
        socket.assigns[:servers] || [],
        socket.assigns[:command_palette_query] || ""
      )

    idx = socket.assigns[:command_palette_index] || 0

    cmd =
      if is_binary(params["id"]) do
        Enum.find(items, &(&1.id == params["id"]))
      else
        Enum.at(items, idx)
      end

    socket =
      assign(socket,
        command_palette_open: false,
        command_palette_query: "",
        command_palette_index: 0
      )

    cond do
      is_nil(cmd) ->
        {:noreply, socket}

      is_binary(cmd[:path]) ->
        {:noreply, push_navigate(socket, to: cmd.path)}

      is_binary(cmd[:event]) ->
        handle_event(cmd.event, %{}, socket)

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("deploy_ssh_key", _params, socket) do
    key_info = socket.assigns[:deploy_key_info]
    server = socket.assigns[:server]
    user = socket.assigns[:target_user] || (server && server.user) || "root"

    if key_info && server do
      case SSHClient.SSH.KeyDeployer.deploy(server, key_info.content, user: user) do
        {:ok, :deployed} ->
          {:noreply,
           socket
           |> assign(
             deploy_status: :success,
             show_deploy_modal: false,
             deploy_message: "SSH Key deployed successfully. Passwordless login enabled."
           )
           |> push_event("terminal_output", %{
             data:
               "\r\n\x1b[1;32m[ssh-client]\x1b[0m Public key (#{key_info.filename}) deployed to #{user}@#{server.id}. Passwordless login enabled.\r\n"
           })}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(
             deploy_status: :error,
             deploy_message: "Failed to deploy key: #{inspect(reason)}"
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_deploy_modal", _params, socket) do
    {:noreply, assign(socket, show_deploy_modal: false, deploy_status: :dismissed)}
  end

  def handle_event("lock_vault", _params, socket) do
    Vault.lock()
    {:noreply, push_navigate(socket, to: "/lock")}
  end

  def handle_event("handle_key", %{"key" => key} = params, socket) do
    ctrl? = params["ctrlKey"] == true or params["metaKey"] == true

    cond do
      ctrl? and params["shiftKey"] == true and key in ["\\", "|"] ->
        handle_event("split_right", %{}, socket)

      ctrl? and params["shiftKey"] == true and key in ["-", "_"] ->
        handle_event("split_down", %{}, socket)

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

  def handle_event("handle_key", _params, socket), do: {:noreply, socket}
  def handle_event("noop", _params, socket), do: {:noreply, socket}

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

        servers = list_all_servers()

        socket =
          socket
          |> put_flash(:info, msg)
          |> assign(:servers, servers)
          |> assign(:online_count, count_online(servers))

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to scan ~/.ssh/config: #{reason}")}
    end
  end

  # ---------------------------------------------------------------------------
  # SessionWorker PubSub
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:ensure_session, socket) do
    tab = active_tab(socket)

    socket =
      if tab && is_nil(tab_session_id(tab)) do
        socket
        |> start_tab_session(tab.id)
        |> maybe_restore_layout_panes()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:pty_output, session_id, data}, socket) do
    {:noreply, push_session_output(socket, session_id, data)}
  end

  def handle_info({:session_status, session_id, status}, socket) do
    connected? = status == :connected

    socket =
      update_tab_by_session(socket, session_id, fn t ->
        %{
          t
          | connected: connected?,
            status: status,
            error: if(connected?, do: nil, else: t.error)
        }
      end)

    socket =
      if connected? do
        maybe_prompt_key_deploy(socket)
      else
        socket
      end

    msg =
      case status do
        :connected -> "\x1b[1;32mConnected to #{socket.assigns.server_id}\x1b[0m\r\n"
        :connecting -> "\x1b[1;34mConnecting...\x1b[0m\r\n"
        :reconnecting -> "\x1b[1;33mReconnecting...\x1b[0m\r\n"
        :disconnected -> "\x1b[2mDisconnected\x1b[0m\r\n"
        :error -> "\x1b[1;31mConnection error\x1b[0m\r\n"
        _ -> nil
      end

    {:noreply, if(msg, do: push_session_output(socket, session_id, msg), else: socket)}
  end

  def handle_info({:session_error, session_id, reason}, socket) do
    err_str = format_error_reason(reason)
    ActivityLog.error(socket.assigns.server_id, "Session error: #{err_str}", reason)

    socket =
      update_tab_by_session(socket, session_id, fn t ->
        Map.merge(t, %{connected: false, error: err_str, status: :error})
      end)

    msg =
      "\r\n\x1b[1;31m[SSH Connection Error]\x1b[0m #{err_str}\r\n" <>
        "\x1b[2mCheck host, port, credentials, or open Logs.\x1b[0m\r\n"

    {:noreply, push_session_output(socket, session_id, msg)}
  end

  def handle_info({:ssh_host_key_event, _session_id, event_type, details}, socket) do
    {:noreply, assign(socket, :host_key_prompt, %{type: event_type, details: details})}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    # SessionWorkers are supervised independently of LiveView.
    :ok
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(%{server_id: nil} = assigns) do
    ~H"""
    <div class="min-h-screen bg-background text-foreground flex flex-col font-sans">
      <.top_navigation
        current_tab={:terminal}
        servers_count={length(@servers)}
        online_count={@online_count}
      />
      <main class="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-8 flex flex-col gap-6">
        <!-- Header Section -->
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-border pb-6">
          <div>
            <h1 class="text-2xl font-bold tracking-tight text-foreground flex items-center gap-2">
              <span>Terminal Sessions</span>
            </h1>

            <p class="text-sm text-muted-foreground mt-1">
              Launch an interactive SSH terminal with multi-tab support, PTY multiplexing, and command autocomplete.
            </p>
          </div>

          <div class="flex items-center gap-2.5">
            <button
              phx-click="scan_and_import_ssh_config"
              class="h-9 px-3.5 bg-secondary hover:bg-secondary/80 border border-border text-foreground font-mono text-xs rounded-md shadow-sm transition-colors inline-flex items-center gap-2"
              title="Scan and import hosts from ~/.ssh/config"
            >
              <span>Import ~/.ssh/config</span>
            </button>

            <a
              href="/?action=new"
              class="h-9 px-3.5 bg-primary text-primary-foreground hover:bg-primary/90 font-mono text-xs rounded-md shadow-sm transition-colors inline-flex items-center gap-1.5 font-medium"
            >
              <span>+ Add Host</span>
            </a>
          </div>
        </div>
        <!-- Flash alerts -->
        <%= if flash = Phoenix.Flash.get(@flash, :info) do %>
          <div class="p-3.5 rounded-lg bg-primary/10 border border-primary/20 text-xs font-mono text-primary flex items-center justify-between">
            <span>{flash}</span>
          </div>
        <% end %>

        <%= if flash = Phoenix.Flash.get(@flash, :error) do %>
          <div class="p-3.5 rounded-lg bg-destructive/10 border border-destructive/20 text-xs font-mono text-destructive flex items-center justify-between">
            <span>{flash}</span>
          </div>
        <% end %>
        <!-- Server Cards or Empty State -->
        <%= if length(@servers) == 0 do %>
          <div class="shadcn-card p-12 text-center flex flex-col items-center justify-center gap-4">
            <div class="w-12 h-12 rounded-full bg-muted flex items-center justify-center font-mono font-bold text-base text-muted-foreground">
              &gt;_
            </div>

            <div class="space-y-1">
              <h3 class="text-base font-semibold text-foreground">No Hosts Configured</h3>

              <p class="text-xs text-muted-foreground max-w-sm">
                Add a host manually or import your existing SSH config from ~/.ssh/config to launch a terminal.
              </p>
            </div>

            <div class="flex items-center gap-3 pt-2">
              <button
                phx-click="scan_and_import_ssh_config"
                class="h-9 px-4 bg-secondary hover:bg-secondary/80 border border-border text-foreground font-mono text-xs rounded-md shadow-sm transition-colors"
              >
                Import ~/.ssh/config
              </button>

              <a
                href="/?action=new"
                class="h-9 px-4 bg-primary text-primary-foreground hover:bg-primary/90 font-mono text-xs rounded-md shadow-sm transition-colors font-medium"
              >
                + Add Host
              </a>
            </div>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <%= for s <- @servers do %>
              <div class="shadcn-card p-5 flex flex-col justify-between gap-4 transition-all hover:border-muted-foreground/30">
                <div>
                  <div class="flex items-start justify-between gap-2">
                    <div class="flex items-center gap-2 min-w-0">
                      <span class={[
                        "w-2 h-2 rounded-full shrink-0",
                        if(s[:status] in ["online", "healthy", :online, :healthy],
                          do: "bg-emerald-500",
                          else: "bg-muted-foreground/40"
                        )
                      ]}></span>
                      <h3 class="font-semibold text-sm text-foreground truncate">
                        {s[:name] || s[:id] || s["name"] || s["id"]}
                      </h3>
                    </div>

                    <span class="text-[10px] font-mono text-muted-foreground bg-muted px-1.5 py-0.5 rounded border border-border shrink-0">
                      Port {s[:port] || s["port"] || 22}
                    </span>
                  </div>

                  <div class="mt-2 space-y-1">
                    <div class="text-xs font-mono text-muted-foreground flex items-center gap-1 truncate">
                      <span>{s[:user] || s["user"] || "root"}@{s[:host] || s["host"] || "localhost"}</span>
                    </div>

                    <%= if s[:proxy_jump] || s["proxy_jump"] do %>
                      <div class="text-[11px] font-mono text-muted-foreground/80 flex items-center gap-1 truncate">
                        <span>Jump: {s[:proxy_jump] || s["proxy_jump"]}</span>
                      </div>
                    <% end %>
                  </div>
                </div>

                <div class="pt-3 border-t border-border flex items-center justify-between gap-2">
                  <a
                    href={"/sftp/#{s[:id] || s["id"]}"}
                    class="h-8 px-2.5 bg-secondary hover:bg-secondary/80 border border-border text-foreground font-mono text-xs rounded transition-colors inline-flex items-center"
                  >
                    SFTP
                  </a>

                  <a
                    href={"/terminal/#{s[:id] || s["id"]}"}
                    class="h-8 px-3.5 bg-primary text-primary-foreground hover:bg-primary/90 font-mono text-xs font-medium rounded shadow-sm transition-colors inline-flex items-center gap-1.5"
                  >
                    <span>Connect &rarr;</span>
                  </a>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </main>
    </div>
    """
  end

  def render(assigns) do
    filtered_commands =
      filter_commands(assigns.all_commands, assigns.selected_category, assigns.command_search)

    assigns = assign(assigns, :filtered_commands, filtered_commands)

    cur_tab =
      Enum.find(assigns.tabs, fn t -> t.id == assigns.active_tab_id end) || hd(assigns.tabs)

    assigns = assign(assigns, :cur_tab, cur_tab)

    ~H"""
    <div
      class="flex flex-col h-screen w-screen bg-background text-foreground overflow-hidden select-none font-sans"
      phx-window-keydown="handle_key"
    >
      <!-- Terminal topbar -->
      <div class="h-12 flex items-center justify-between px-3 bg-card/90 border-b border-border shrink-0 z-20">
        <!-- Left: Host back nav, Server ID, BETA badge, Multi-tab bar -->
        <div class="flex items-center gap-2 min-w-0">
          <a
            href="/"
            class="text-muted-foreground hover:text-foreground text-xs font-mono transition-colors inline-flex items-center gap-1 px-2.5 py-1 rounded bg-secondary hover:bg-secondary/80 border border-border shrink-0"
            title="Back to Hosts"
          >
            &larr; <span class="hidden sm:inline">Hosts</span>
          </a>
          <span class="text-border">|</span>
          <span class="text-foreground text-xs font-mono font-semibold truncate">{@server_id}</span>
          <span class="px-1.5 py-0.5 text-[9px] font-mono font-semibold uppercase tracking-wider rounded bg-destructive/10 text-destructive border border-destructive/20">BETA</span>
          <!-- Multi-Tab workspace pills -->
          <div class="hidden sm:flex items-center gap-1 pl-1.5 border-l border-border">
            <%= for tab <- @tabs do %>
              <div class={[
                "flex items-center rounded font-mono text-xs overflow-hidden border transition-colors",
                if(tab.id == @active_tab_id,
                  do: "bg-background border-border text-foreground font-semibold shadow-sm",
                  else:
                    "bg-muted/50 border-transparent text-muted-foreground hover:text-foreground hover:bg-muted"
                )
              ]}>
                <button
                  phx-click="switch_tab"
                  phx-value-id={tab.id}
                  class="px-2.5 py-1 text-left flex items-center gap-1.5"
                >
                  <span class={[
                    "w-1.5 h-1.5 rounded-full",
                    if(tab.connected, do: "bg-emerald-500", else: "bg-muted-foreground")
                  ]}></span> <span>{tab.title}</span>
                </button>

                <%= if length(@tabs) > 1 do %>
                  <button
                    phx-click="close_tab"
                    phx-value-id={tab.id}
                    class="px-1.5 py-1 text-muted-foreground hover:text-destructive transition-colors"
                    title="Close Tab"
                  >
                    &times;
                  </button>
                <% end %>
              </div>
            <% end %>

            <button
              phx-click="new_tab"
              class="h-6 px-2 bg-secondary hover:bg-secondary/80 border border-border text-muted-foreground hover:text-foreground rounded text-xs font-mono transition-colors"
              title="Open New Terminal Tab"
            >
              +
            </button>

            <button
              phx-click="split_right"
              class="h-6 px-2 bg-secondary hover:bg-secondary/80 border border-border text-muted-foreground hover:text-foreground rounded text-xs font-mono transition-colors"
              title="Split Right"
            >
              Split Right
            </button>

            <button
              phx-click="split_down"
              class="h-6 px-2 bg-secondary hover:bg-secondary/80 border border-border text-muted-foreground hover:text-foreground rounded text-xs font-mono transition-colors"
              title="Split Down"
            >
              Split Down
            </button>
          </div>
        </div>
        <!-- Center / Right: Quick Controls & Status -->
        <div class="flex items-center gap-2">
          <!-- Connection badge for active tab -->
          <span class={[
            "inline-flex items-center gap-1.5 text-[11px] font-mono px-2.5 py-0.5 rounded-full border shrink-0",
            if(@cur_tab.connected,
              do: "bg-emerald-500/10 text-emerald-500 border-emerald-500/20",
              else:
                if(@cur_tab.error,
                  do: "bg-destructive/10 text-destructive border-destructive/20",
                  else: "bg-blue-500/10 text-blue-500 border-blue-500/20"
                )
            )
          ]}>
            <span class={[
              "w-1.5 h-1.5 rounded-full",
              if(@cur_tab.connected,
                do: "bg-emerald-500 animate-pulse",
                else: if(@cur_tab.error, do: "bg-destructive", else: "bg-blue-500 animate-ping")
              )
            ]}></span>
            <span class="hidden md:inline">{if @cur_tab.connected,
              do: "connected",
              else: if(@cur_tab.error, do: "error", else: "connecting...")}</span>
          </span>

          <span class="text-muted-foreground text-[10px] font-mono hidden lg:inline">{@cols}x{@rows}</span>
          <!-- SFTP Quick Link -->
          <a
            href={"/sftp/#{@server_id}"}
            class="h-7 px-2.5 bg-secondary hover:bg-secondary/80 border border-border text-secondary-foreground text-xs rounded-md transition-colors font-mono inline-flex items-center shadow-sm"
            title="Open SFTP File Explorer"
          >
            SFTP
          </a>
          <!-- Quick Action: Paste -->
          <button
            phx-click="request_paste"
            class="h-7 px-2.5 bg-secondary hover:bg-secondary/80 border border-border text-secondary-foreground text-xs rounded-md transition-colors font-mono inline-flex items-center shadow-sm"
            title="Paste Clipboard (Ctrl+V)"
          >
            Paste
          </button>
          <!-- Quick Action: Toggle Commands Drawer -->
          <button
            phx-click="toggle_commands"
            class={[
              "h-7 px-2.5 border text-xs rounded-md transition-colors font-mono inline-flex items-center shadow-sm",
              if(@show_commands,
                do: "bg-primary text-primary-foreground border-primary",
                else: "bg-secondary hover:bg-secondary/80 border-border text-secondary-foreground"
              )
            ]}
            title="Toggle Command Autocomplete & Suggestions"
          >
            Cmds
          </button>
          <!-- Quick Action: Switch to Zsh -->
          <button
            phx-click="switch_to_zsh"
            class="h-7 px-2.5 bg-secondary hover:bg-secondary/80 border border-border text-secondary-foreground text-xs rounded-md transition-colors font-mono inline-flex items-center shadow-sm"
            title="Switch remote shell to Zsh (exec zsh -l)"
          >
            Zsh
          </button>
          <!-- Quick Action: Clear Screen -->
          <button
            phx-click="clear_screen"
            class="h-7 px-2 bg-secondary hover:bg-secondary/80 border border-border text-muted-foreground hover:text-foreground text-xs rounded-md transition-colors font-mono"
            title="Clear Terminal Screen (Ctrl+L)"
          >
            Clear
          </button>
          <!-- Font Size Adjusters -->
          <div class="hidden sm:flex items-center border border-border rounded-md bg-secondary overflow-hidden">
            <button
              phx-click="font_decrease"
              class="h-7 px-2 text-[11px] text-muted-foreground hover:text-foreground hover:bg-accent transition-colors font-mono"
              title="Decrease Font Size (Ctrl -)"
            >
              A-
            </button>
            <span class="w-[1px] h-4 bg-border"></span>
            <button
              phx-click="font_increase"
              class="h-7 px-2 text-[11px] text-muted-foreground hover:text-foreground hover:bg-accent transition-colors font-mono"
              title="Increase Font Size (Ctrl +)"
            >
              A+
            </button>
          </div>
          <!-- Reconnect -->
          <button
            phx-click="reconnect"
            class="h-7 px-2.5 bg-secondary hover:bg-secondary/80 border border-border text-secondary-foreground text-xs rounded-md transition-colors font-mono shadow-sm"
            title="Reconnect Session"
          >
            Reconnect
          </button>

          <button
            phx-click="maximize_pane"
            class="h-7 px-2.5 bg-secondary hover:bg-secondary/80 border border-border text-secondary-foreground text-xs rounded-md transition-colors font-mono shadow-sm"
          >
            Maximize
          </button>

          <button
            phx-click="restore_panes"
            class="h-7 px-2.5 bg-secondary hover:bg-secondary/80 border border-border text-secondary-foreground text-xs rounded-md transition-colors font-mono shadow-sm"
          >
            Restore
          </button>
          <!-- Logs -->
          <a
            href="/logs"
            class="h-7 px-2.5 bg-secondary hover:bg-secondary/80 border border-border text-muted-foreground hover:text-foreground text-xs rounded-md transition-colors font-mono inline-flex items-center"
            title="View Real-Time Logs"
          >
            Logs
          </a>
        </div>
      </div>
      <!-- Main Body: Terminal + Docked Command Palette -->
      <div class="flex-1 flex flex-col min-h-0 w-full relative bg-background">
        <% layout = @cur_tab[:layout]

        panes =
          cond do
            match?(%SSHClient.Terminal.Layout{}, layout) && layout.maximized ->
              [layout.maximized]

            match?(%SSHClient.Terminal.Layout{}, layout) ->
              SSHClient.Terminal.Layout.panes(layout)

            true ->
              []
          end

        grid_class =
          cond do
            layout && layout.maximized -> "flex"
            layout && layout.type == :split_h -> "grid grid-cols-2 gap-1"
            layout && layout.type == :split_v -> "grid grid-rows-2 gap-1"
            layout && layout.type == :grid -> "grid grid-cols-2 grid-rows-2 gap-1"
            true -> "flex"
          end %>
        <%= if panes != [] do %>
          <div class={"flex-1 min-h-0 w-full h-full " <> grid_class}>
            <%= for pane_id <- panes do %>
              <div
                id={"terminal-pane-#{pane_id}"}
                phx-hook="TerminalPane"
                phx-click="focus_pane"
                phx-value-pane_id={pane_id}
                data-session-id={pane_id}
                data-pane-id={pane_id}
                class="min-h-0 h-full w-full overflow-hidden border border-border"
              >
              </div>
            <% end %>
          </div>
        <% else %>
          <div
            id="xterm-container"
            phx-hook="TerminalHook"
            phx-update="ignore"
            class="flex-1 w-full h-full min-h-0 overflow-hidden"
            data-server-id={@server_id}
            data-cols={@cols}
            data-rows={@rows}
          >
          </div>
        <% end %>
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
                  class={[
                    "px-2 py-0.5 rounded transition-colors",
                    if(@selected_category == "all",
                      do: "bg-blue-600 text-white font-medium",
                      else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]"
                    )
                  ]}
                >
                  All
                </button>

                <button
                  phx-click="select_category"
                  phx-value-cat="zsh"
                  class={[
                    "px-2 py-0.5 rounded transition-colors",
                    if(@selected_category == "zsh",
                      do: "bg-blue-600 text-white font-medium",
                      else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]"
                    )
                  ]}
                >
                  Zsh
                </button>

                <button
                  phx-click="select_category"
                  phx-value-cat="sys"
                  class={[
                    "px-2 py-0.5 rounded transition-colors",
                    if(@selected_category == "sys",
                      do: "bg-blue-600 text-white font-medium",
                      else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]"
                    )
                  ]}
                >
                  System
                </button>

                <button
                  phx-click="select_category"
                  phx-value-cat="docker"
                  class={[
                    "px-2 py-0.5 rounded transition-colors",
                    if(@selected_category == "docker",
                      do: "bg-blue-600 text-white font-medium",
                      else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]"
                    )
                  ]}
                >
                  Docker
                </button>

                <button
                  phx-click="select_category"
                  phx-value-cat="services"
                  class={[
                    "px-2 py-0.5 rounded transition-colors",
                    if(@selected_category == "services",
                      do: "bg-blue-600 text-white font-medium",
                      else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]"
                    )
                  ]}
                >
                  Services
                </button>

                <button
                  phx-click="select_category"
                  phx-value-cat="net"
                  class={[
                    "px-2 py-0.5 rounded transition-colors",
                    if(@selected_category == "net",
                      do: "bg-blue-600 text-white font-medium",
                      else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]"
                    )
                  ]}
                >
                  Network
                </button>

                <button
                  phx-click="select_category"
                  phx-value-cat="files"
                  class={[
                    "px-2 py-0.5 rounded transition-colors",
                    if(@selected_category == "files",
                      do: "bg-blue-600 text-white font-medium",
                      else: "text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f1f]"
                    )
                  ]}
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
                      <span class="text-xs font-medium text-zinc-200 font-mono">{item.label}</span>
                      <span class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-[#202024] text-zinc-400 font-mono">{item.cat}</span>
                    </div>

                    <p class="text-[11px] text-zinc-500 leading-tight mb-2">{item.desc}</p>

                    <code class="text-[11px] font-mono text-blue-400 bg-[#09090b] px-2 py-1 rounded block truncate border border-[#1b1b1f] select-text">
                      {item.cmd}
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
                  No command suggestions match "{@command_search}"
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
        <!-- Auto Deploy SSH Key Prompt Modal -->
        <%= if @show_deploy_modal and @deploy_key_info do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/75 backdrop-blur-sm p-4">
            <div class="w-full max-w-md bg-[#121214] border border-[#27272a] rounded-xl shadow-2xl p-5 font-mono">
              <div class="flex items-center justify-between pb-3 border-b border-[#27272a] mb-4">
                <div class="flex items-center gap-2">
                  <span class="w-2 h-2 rounded-full bg-blue-500 animate-pulse"></span>
                  <h3 class="text-sm font-semibold text-zinc-100">Deploy SSH Key</h3>
                </div>

                <button
                  phx-click="dismiss_deploy_modal"
                  class="text-zinc-500 hover:text-zinc-300 text-xs px-2 py-0.5 rounded hover:bg-[#1f1f23] transition-colors"
                >
                  Skip
                </button>
              </div>

              <p class="text-xs text-zinc-300 leading-relaxed mb-3">
                You connected using password authentication. Would you like to install your local public key (<span class="text-blue-400 font-semibold"><%= @deploy_key_info.filename %></span>) onto
                <span class="text-zinc-100 font-semibold">{@target_user || (@server && @server.user) ||
                  "root"}@{@server_id}</span>
                for passwordless login?
              </p>

              <div class="bg-[#09090b] border border-[#1f1f23] rounded-lg p-2.5 mb-4 text-[11px] text-zinc-400 truncate">
                <span class="text-zinc-500">Key Path: </span>
                <span class="text-zinc-300">{@deploy_key_info.path}</span>
              </div>

              <%= if @deploy_status == :error do %>
                <div class="p-2.5 rounded bg-red-950/40 border border-red-800/60 text-red-300 text-xs mb-4">
                  {@deploy_message}
                </div>
              <% end %>

              <div class="flex items-center justify-end gap-2 pt-2 border-t border-[#1f1f23]">
                <button
                  type="button"
                  phx-click="dismiss_deploy_modal"
                  class="px-3 py-1.5 rounded-lg text-xs text-zinc-400 hover:text-zinc-200 hover:bg-[#1f1f23] transition-colors"
                >
                  Don't Ask Again
                </button>

                <button
                  type="button"
                  phx-click="deploy_ssh_key"
                  class="px-4 py-1.5 rounded-lg text-xs font-medium bg-blue-600 hover:bg-blue-500 text-white transition-colors shadow-sm inline-flex items-center gap-1.5"
                >
                  Deploy Key (Passwordless)
                </button>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>

    <%= if @host_key_prompt do %>
      <div class="fixed inset-0 z-[70] bg-black/70 flex items-center justify-center p-4">
        <div class="bg-card border border-border rounded-xl p-6 w-full max-w-lg space-y-3 font-mono">
          <h3 class="text-sm font-semibold text-foreground">
            {if @host_key_prompt[:type] in [:host_key_changed, "host_key_changed"],
              do: "Host key changed",
              else: "New host key"}
          </h3>

          <p class="text-xs text-muted-foreground">
            Verify this fingerprint before trusting the host. Changed keys can indicate a MITM attack.
          </p>
          <pre class="text-[11px] bg-background border border-border rounded p-3 overflow-x-auto"><%= inspect(@host_key_prompt[:details]) %></pre>
          <div class="flex justify-end gap-2">
            <button phx-click="reject_host_key" class="h-8 px-3 text-xs text-destructive">Reject</button>
            <button
              phx-click="accept_host_key"
              class="h-8 px-3 bg-primary text-primary-foreground text-xs rounded"
            >Trust host</button>
          </div>
        </div>
      </div>
    <% end %>

    <%= if @command_palette_open do %>
      <% items = CommandPalette.items(@servers, @command_palette_query) %>
      <div class="fixed inset-0 z-[80] bg-black/50" phx-click="close_command_palette">
        <div
          class="mx-auto mt-[12vh] w-full max-w-xl bg-card border border-border rounded-lg shadow-2xl overflow-hidden"
          phx-click="noop"
        >
          <form phx-change="command_palette_search" phx-submit="run_palette_command">
            <input
              type="text"
              name="query"
              value={@command_palette_query}
              phx-debounce="50"
              autofocus
              placeholder="Type a command or host name..."
              class="w-full h-11 px-4 bg-background border-b border-border text-sm font-mono text-foreground focus:outline-none"
            />
          </form>

          <div class="max-h-[50vh] overflow-y-auto py-1">
            <%= if items == [] do %>
              <div class="px-4 py-6 text-xs text-muted-foreground font-mono">
                No matching commands.
              </div>
            <% else %>
              <%= for {item, idx} <- Enum.with_index(items) do %>
                <button
                  type="button"
                  phx-click="run_palette_command"
                  phx-value-id={item.id}
                  class={[
                    "w-full text-left px-4 py-2 text-xs font-mono flex items-center justify-between",
                    if(idx == @command_palette_index,
                      do: "bg-muted text-foreground",
                      else: "text-muted-foreground hover:bg-muted/60 hover:text-foreground"
                    )
                  ]}
                >
                  <span>{item.label}</span> <span class="text-[10px] opacity-70">{item.hint}</span>
                </button>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
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
    case socket.assigns[:tabs] do
      [first | _] = tabs ->
        Enum.find(tabs, fn t -> t.id == socket.assigns.active_tab_id end) || first

      _ ->
        nil
    end
  end

  defp list_all_servers do
    try do
      ServerManager.list_servers()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp count_online(servers) when is_list(servers) do
    Enum.count(servers, fn s ->
      status = s[:status] || s["status"]
      status in ["online", "healthy", :online, :healthy]
    end)
  end

  defp count_online(_), do: 0

  defp update_tab(socket, tab_id, fun) when is_function(fun, 1) do
    new_tabs =
      Enum.map(socket.assigns.tabs, fn t ->
        if t.id == tab_id, do: fun.(t), else: t
      end)

    assign(socket, :tabs, new_tabs)
  end

  defp update_tab_by_session(socket, session_id, fun) when is_function(fun, 1) do
    new_tabs =
      Enum.map(socket.assigns.tabs, fn t ->
        if session_id in tab_session_ids(t), do: fun.(t), else: t
      end)

    assign(socket, :tabs, new_tabs)
  end

  defp start_tab_session(socket, nil), do: socket

  defp start_tab_session(socket, tab_id) do
    case socket.assigns.server do
      %Server{} = server ->
        opts = session_connect_opts(socket)

        case SessionManager.create_session(server, opts) do
          {:ok, session_id} ->
            subscribe_session(session_id)

            {:ok, pid} =
              case SessionManager.get_session(session_id) do
                {:ok, p} -> {:ok, p}
                _ -> {:ok, nil}
              end

            socket
            |> update_tab(tab_id, fn t ->
              %{
                t
                | session_id: session_id,
                  session_pid: pid,
                  layout: Layout.new(session_id),
                  error: nil,
                  status: :connecting
              }
            end)
            |> assign(:active_pane_id, session_id)

          {:error, reason} ->
            err_str = "Failed to start terminal session: #{inspect(reason)}"
            ActivityLog.error(socket.assigns.server_id, err_str, reason)

            socket
            |> update_tab(tab_id, fn t ->
              Map.merge(t, %{connected: false, error: err_str, status: :error})
            end)
            |> push_event("terminal_output", %{
              data: "\r\n\x1b[1;31m[Error]\x1b[0m #{err_str}\r\n"
            })
        end

      nil ->
        err_str = "Host '#{socket.assigns.server_id}' not found in configuration."
        ActivityLog.error(socket.assigns.server_id, err_str)

        socket
        |> update_tab(tab_id, fn t ->
          Map.merge(t, %{connected: false, error: err_str, status: :error})
        end)
        |> push_event("terminal_output", %{
          data: "\r\n\x1b[1;31m[Configuration Error]\x1b[0m #{err_str}\r\n"
        })
    end
  end

  defp session_connect_opts(socket) do
    opts = [cols: socket.assigns.cols, rows: socket.assigns.rows, auto_connect: true]

    opts =
      if socket.assigns[:target_user] && socket.assigns[:target_user] != "" do
        Keyword.put(opts, :user, socket.assigns[:target_user])
      else
        opts
      end

    if socket.assigns[:target_auth] && socket.assigns[:target_auth] != "" do
      auth_atom =
        if socket.assigns[:target_auth] in ["password", :password], do: :password, else: :key

      Keyword.put(opts, :auth_method, auth_atom)
    else
      opts
    end
  end

  defp restore_or_prepare_sessions(socket) do
    existing = SessionManager.list_for_server(socket.assigns.server_id)

    if existing == [] do
      case Store.get(:sessions, socket.assigns.server_id) do
        %{"pane_count" => count} = saved when is_integer(count) and count > 1 ->
          assign(socket, :restore_layout, saved)

        _ ->
          socket
      end
    else
      Enum.each(existing, &subscribe_session(&1.session_id))

      existing_ids = Enum.map(existing, & &1.session_id)
      saved = Store.get(:sessions, socket.assigns.server_id)
      restored = layout_from_store(saved, existing_ids)

      tabs =
        if restored do
          first_id = restored.active_pane || hd(restored.panes)
          entry = Enum.find(existing, &(&1.session_id == first_id)) || hd(existing)

          [
            %{
              id: 1,
              title: "Shell 1",
              layout: restored,
              session_id: entry.session_id,
              session_pid: entry.pid,
              connected: entry.status == :connected,
              error: nil,
              status: entry.status
            }
          ]
        else
          existing
          |> Enum.with_index(1)
          |> Enum.map(fn {entry, idx} ->
            %{
              id: idx,
              title: "Shell #{idx}",
              layout: Layout.new(entry.session_id),
              session_id: entry.session_id,
              session_pid: entry.pid,
              connected: entry.status == :connected,
              error: nil,
              status: entry.status
            }
          end)
        end

      first = hd(tabs)

      active_pane =
        if restored, do: restored.active_pane || first.session_id, else: first.session_id

      socket
      |> assign(:tabs, tabs)
      |> assign(:active_tab_id, first.id)
      |> assign(:next_tab_id, length(tabs) + 1)
      |> assign(:active_pane_id, active_pane)
    end
  end

  defp persist_layout(socket) do
    tab = active_tab(socket)
    server_id = socket.assigns[:server_id]

    if tab && tab.layout && is_binary(server_id) do
      _ =
        Store.put(:sessions, server_id, %{
          "id" => server_id,
          "layout_type" => to_string(tab.layout.type),
          "pane_ids" => tab.layout.panes,
          "active_pane" => tab.layout.active_pane,
          "maximized" => tab.layout.maximized,
          "pane_count" => length(tab.layout.panes),
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })
    end

    socket
  rescue
    _ -> socket
  end

  defp maybe_restore_layout_panes(socket) do
    case socket.assigns[:restore_layout] do
      %{"pane_count" => count, "layout_type" => type} = saved
      when is_integer(count) and count > 1 ->
        direction = if type in ["split_v", :split_v], do: :vertical, else: :horizontal

        socket =
          Enum.reduce(2..count, socket, fn _i, acc ->
            tab_now = active_tab(acc)
            server = acc.assigns.server

            if tab_now && server do
              case SessionManager.create_session(server, session_connect_opts(acc)) do
                {:ok, new_session_id} ->
                  subscribe_session(new_session_id)

                  cur_layout =
                    tab_now.layout || Layout.new(tab_session_id(tab_now) || new_session_id)

                  target = acc.assigns[:active_pane_id] || Layout.active_pane(cur_layout)
                  new_layout = Layout.split(cur_layout, target, direction, new_session_id)

                  acc
                  |> update_tab(tab_now.id, fn t -> %{t | layout: new_layout} end)
                  |> assign(:active_pane_id, new_session_id)

                _ ->
                  acc
              end
            else
              acc
            end
          end)

        socket =
          if saved["maximized"] do
            tab_now = active_tab(socket)

            if tab_now && tab_now.layout do
              max_pane = socket.assigns[:active_pane_id]

              update_tab(socket, tab_now.id, fn t ->
                %{t | layout: Layout.maximize(t.layout, max_pane)}
              end)
            else
              socket
            end
          else
            socket
          end

        socket
        |> assign(:restore_layout, nil)
        |> persist_layout()

      _ ->
        socket
    end
  end

  defp layout_from_store(nil, _existing_ids), do: nil

  defp layout_from_store(saved, existing_ids) when is_map(saved) do
    pane_ids = saved["pane_ids"] || saved[:pane_ids] || []

    if is_list(pane_ids) and pane_ids != [] and Enum.all?(pane_ids, &(&1 in existing_ids)) do
      type =
        case saved["layout_type"] || saved[:layout_type] do
          "split_h" -> :split_h
          "split_v" -> :split_v
          "grid" -> :grid
          :split_h -> :split_h
          :split_v -> :split_v
          :grid -> :grid
          _ -> if(length(pane_ids) > 1, do: :split_h, else: :single)
        end

      active = saved["active_pane"] || saved[:active_pane]
      maximized = saved["maximized"] || saved[:maximized]

      %Layout{
        type: type,
        panes: pane_ids,
        active_pane: if(active in pane_ids, do: active, else: hd(pane_ids)),
        maximized: if(maximized in pane_ids, do: maximized, else: nil)
      }
    else
      nil
    end
  end

  defp do_split(socket, direction, _params) do
    tab = active_tab(socket)
    server = socket.assigns.server

    if is_nil(tab) or is_nil(server) do
      socket
      |> then(&{:noreply, &1})
    else
      case SessionManager.create_session(server, session_connect_opts(socket)) do
        {:ok, new_session_id} ->
          subscribe_session(new_session_id)
          current_layout = tab.layout || Layout.new(tab_session_id(tab) || new_session_id)
          target = socket.assigns[:active_pane_id] || Layout.active_pane(current_layout)
          new_layout = Layout.split(current_layout, target, direction, new_session_id)

          socket =
            socket
            |> update_tab(tab.id, fn t ->
              %{t | layout: new_layout, session_id: new_session_id}
            end)
            |> assign(:active_pane_id, new_session_id)
            |> persist_layout()

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, :error, "Failed to split pane: #{inspect(reason)}")}
      end
    end
  end

  defp send_pane_input(socket, params) do
    data = params["data"]

    pane_id =
      params["pane_id"] || socket.assigns[:active_pane_id] || tab_session_id(active_tab(socket))

    if is_binary(data) do
      send_session_input(pane_id, data)
    end

    {:noreply, socket}
  end

  defp send_to_active(socket, data) do
    pane_id = socket.assigns[:active_pane_id] || tab_session_id(active_tab(socket))
    send_session_input(pane_id, data)
  end

  defp send_session_input(nil, _data), do: :ok

  defp send_session_input(session_id, data) do
    case SessionManager.get_session(session_id) do
      {:ok, pid} when is_pid(pid) -> SessionWorker.send_input(pid, data)
      _ -> :ok
    end
  end

  defp resize_session(session_id, cols, rows) do
    case SessionManager.get_session(session_id) do
      {:ok, pid} when is_pid(pid) -> SessionWorker.resize(pid, cols, rows)
      _ -> :ok
    end
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp tab_session_id(nil), do: nil

  defp tab_session_id(tab) do
    tab[:session_id] || (tab[:layout] && Layout.active_pane(tab.layout))
  end

  defp tab_session_ids(nil), do: []

  defp tab_session_ids(tab) do
    cond do
      match?(%Layout{}, tab[:layout]) -> Layout.panes(tab.layout)
      is_binary(tab[:session_id]) -> [tab.session_id]
      true -> []
    end
  end

  defp replay_tab_buffer(socket, nil), do: socket

  defp replay_tab_buffer(socket, tab) do
    Enum.reduce(tab_session_ids(tab), socket, fn session_id, acc ->
      text =
        case SessionManager.get_session(session_id) do
          {:ok, pid} when is_pid(pid) ->
            snapshot = SessionWorker.get_buffer(pid)
            snapshot[:text] || ""

          _ ->
            ""
        end

      acc
      |> push_event("terminal_clear_#{session_id}", %{})
      |> push_session_output(session_id, text)
    end)
  end

  defp push_session_output(socket, session_id, data) when is_binary(data) and data != "" do
    socket
    |> push_event("terminal_output", %{data: data})
    |> push_event("terminal_output:#{session_id}", %{session_id: session_id, data: data})
    |> push_event("terminal_output_#{session_id}", %{data: data})
  end

  defp push_session_output(socket, _session_id, _data), do: socket

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

  defp update_active_layout(socket, fun) do
    tab = active_tab(socket)

    if tab && tab.layout do
      update_tab(socket, tab.id, fn t -> %{t | layout: fun.(t.layout)} end)
    else
      socket
    end
  end

  defp maybe_prompt_key_deploy(socket) do
    auth_method =
      socket.assigns.target_auth ||
        (socket.assigns.server && socket.assigns.server.default_auth_method)

    if auth_method in ["password", :password] and socket.assigns.deploy_status == :idle do
      case SSHClient.SSH.KeyManager.get_default_public_key() do
        {:ok, key_info} -> assign(socket, show_deploy_modal: true, deploy_key_info: key_info)
        _ -> socket
      end
    else
      socket
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

  defp format_error_reason({:connection_failed, reason}),
    do: "Connection failed: #{format_error_reason(reason)}"

  defp format_error_reason({:connect_failed, reason}),
    do: "Connect failed: #{format_error_reason(reason)}"

  defp format_error_reason({:pty_failed, reason}),
    do: "PTY allocation failed: #{format_error_reason(reason)}"

  defp format_error_reason(:econnrefused),
    do: "Connection refused (econnrefused) - check host & port 22"

  defp format_error_reason(:etimedout), do: "Connection timed out (etimedout)"
  defp format_error_reason(:nxdomain), do: "Host domain name cannot be resolved (nxdomain)"

  defp format_error_reason(:key_exchange_failed),
    do: "Key exchange / host key verification failed"

  defp format_error_reason(:auth_failed),
    do: "Authentication failed - public key or password rejected"

  defp format_error_reason(~c"Host key not accepted"), do: "Host key not accepted"
  defp format_error_reason(str) when is_binary(str), do: str
  defp format_error_reason(other), do: inspect(other)
end
