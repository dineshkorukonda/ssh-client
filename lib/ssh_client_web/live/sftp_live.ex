defmodule SSHClientWeb.SFTPLive do
  @moduledoc """
  Dual-Pane Interactive SFTP Explorer LiveView.
  Features parallel Local & Remote filesystem navigation, bidirectional drag-and-drop,
  streaming transfer queue with progress reporting, inline code/config editor,
  and visual permissions management.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}

  import SSHClientWeb.CoreComponents

  alias SSHClient.Config
  alias SSHClient.Config.Server
  alias SSHClient.LocalFS
  alias SSHClient.ServerManager
  alias SSHClient.SFTP
  alias SSHClient.SFTP.TransferManager
  alias SSHClient.SSH
  alias SSHClient.SSH.ConfigImporter
  alias SSHClient.Vault

  @impl true
  def mount(params, _session, socket) do
    if not Vault.unlocked?() do
      {:ok, push_navigate(socket, to: "/lock")}
    else
      server_id = params["id"]
      servers = list_all_servers()
      online_count = count_online_servers()

      if is_nil(server_id) or server_id == "" do
        socket =
          socket
          |> assign(:page_title, "SFTP File Explorer")
          |> assign(:server_id, nil)
          |> assign(:server, nil)
          |> assign(:servers, servers)
          |> assign(:online_count, online_count)
          |> assign(:conn, nil)
          |> assign(:sftp_pid, nil)
          # Theme
          |> assign(:theme, "dark")
          # Local State
          |> assign(:local_path, LocalFS.default_path())
          |> assign(:local_entries, [])
          |> assign(:local_filter, "")
          |> assign(:show_hidden, false)
          |> assign(:selected_local, nil)
          |> assign(:local_loading, false)
          # Remote State
          |> assign(:remote_path, "/root")
          |> assign(:remote_entries, [])
          |> assign(:remote_filter, "")
          |> assign(:selected_remote, nil)
          |> assign(:remote_loading, false)
          |> assign(:error, nil)
          # Active Transfers & Queue
          |> assign(:transfers, [])
          |> assign(:active_transfer, nil)
          |> assign(:transfer_progress, 0)
          # Modals
          |> assign(:editor_open, false)
          |> assign(:editor_target, nil)
          |> assign(:editor_path, nil)
          |> assign(:editor_content, "")
          |> assign(:editor_saving, false)
          |> assign(:chmod_modal, false)
          |> assign(:chmod_entry, nil)
          |> assign(:chmod_octal, "0755")
          |> assign(:new_folder_modal, false)
          |> assign(:new_folder_target, :remote)
          |> assign(:new_folder_name, "")
          |> assign(:delete_modal, false)
          |> assign(:delete_target, nil)
          |> assign(:delete_path, nil)
          |> assign(:rename_modal, false)
          |> assign(:rename_target, nil)
          |> assign(:rename_path, nil)
          |> assign(:rename_name, "")
          |> assign(:target_user, nil)

        {:ok, socket}
      else
        server = resolve_server_struct(server_id)
        local_start = LocalFS.default_path()

        socket =
          socket
          |> assign(:page_title, "SFTP — #{server_id}")
          |> assign(:server_id, server_id)
          |> assign(:server, server)
          |> assign(:servers, servers)
          |> assign(:online_count, online_count)
          |> assign(:conn, nil)
          |> assign(:sftp_pid, nil)
          # Theme
          |> assign(:theme, "dark")
          # Local State
          |> assign(:local_path, local_start)
          |> assign(:local_entries, [])
          |> assign(:local_filter, "")
          |> assign(:show_hidden, false)
          |> assign(:selected_local, nil)
          |> assign(:local_loading, false)
          # Remote State
          |> assign(:remote_path, "/root")
          |> assign(:remote_entries, [])
          |> assign(:remote_filter, "")
          |> assign(:selected_remote, nil)
          |> assign(:remote_loading, true)
          |> assign(:error, nil)
          # Active Transfers & Queue
          |> assign(:transfers, [])
          |> assign(:active_transfer, nil)
          |> assign(:transfer_progress, 0)
          # Modals
          |> assign(:editor_open, false)
          |> assign(:editor_target, nil)
          |> assign(:editor_path, nil)
          |> assign(:editor_content, "")
          |> assign(:editor_saving, false)
          |> assign(:chmod_modal, false)
          |> assign(:chmod_entry, nil)
          |> assign(:chmod_octal, "0755")
          |> assign(:new_folder_modal, false)
          |> assign(:new_folder_target, :remote)
          |> assign(:new_folder_name, "")
          |> assign(:delete_modal, false)
          |> assign(:delete_target, nil)
          |> assign(:delete_path, nil)
          |> assign(:rename_modal, false)
          |> assign(:rename_target, nil)
          |> assign(:rename_path, nil)
          |> assign(:rename_name, "")
          |> assign(:target_user, nil)

        socket = load_local_dir(socket, local_start)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(SSHClient.PubSub, "ssh_client:transfers")
          send(self(), :connect_sftp)
        end

        {:ok, socket}
      end
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = params["user"]
    {:noreply, assign(socket, :target_user, if(user && user != "", do: user, else: nil))}
  end

  # ---------------------------------------------------------------------------
  # Lifecycle & Connection
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:connect_sftp, socket) do
    server = socket.assigns.server

    if is_nil(server) do
      {:noreply,
       assign(socket,
         remote_loading: false,
         error: "Host '#{socket.assigns.server_id}' not found in configuration."
       )}
    else
      connect_opts =
        if socket.assigns[:target_user] && socket.assigns[:target_user] != "" do
          [user: socket.assigns[:target_user]]
        else
          []
        end

      case SSH.connect(server, connect_opts) do
        {:ok, conn} ->
          case SFTP.start_channel(conn) do
            {:ok, sftp_pid} ->
              target_u = socket.assigns[:target_user] || server.user
              start_path = if target_u == "root", do: "/root", else: "/home/#{target_u || "user"}"

              socket =
                socket
                |> assign(conn: conn, sftp_pid: sftp_pid, remote_path: start_path)
                |> load_remote_dir(start_path)

              {:noreply, socket}

            {:error, reason} ->
              {:noreply,
               assign(socket,
                 remote_loading: false,
                 error: "Failed to open SFTP channel: #{inspect(reason)}"
               )}
          end

        {:error, reason} ->
          {:noreply,
           assign(socket,
             remote_loading: false,
             error: "SSH connection failed: #{inspect(reason)}"
           )}
      end
    end
  end

  def handle_info({:transfer_progress, percent}, socket) do
    {:noreply, assign(socket, transfer_progress: percent)}
  end

  def handle_info({:transfer_done, result, transfer_id}, socket) do
    transfers =
      Enum.map(socket.assigns.transfers, fn t ->
        if t.id == transfer_id do
          case result do
            :ok -> Map.merge(t, %{status: :completed, progress: 100})
            {:error, reason} -> Map.merge(t, %{status: :failed, error: inspect(reason)})
          end
        else
          t
        end
      end)

    {:noreply, assign(socket, transfers: transfers, active_transfer: nil, transfer_progress: 0)}
  end

  def handle_info({:transfer_update, transfer}, socket) when is_map(transfer) do
    socket = refresh_transfers(socket)

    socket =
      if transfer.status in [:completed, :failed] do
        socket
        |> load_local_dir(socket.assigns.local_path)
        |> load_remote_dir(socket.assigns.remote_path)
      else
        socket
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Local Filesystem Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("local_navigate", %{"path" => path}, socket) do
    {:noreply, load_local_dir(socket, path)}
  end

  def handle_event("local_navigate_up", _params, socket) do
    parent = LocalFS.parent_dir(socket.assigns.local_path)
    {:noreply, load_local_dir(socket, parent)}
  end

  def handle_event("local_select", %{"path" => path}, socket) do
    selected = if socket.assigns.selected_local == path, do: nil, else: path
    {:noreply, assign(socket, :selected_local, selected)}
  end

  def handle_event("local_open", %{"path" => path, "type" => "directory"}, socket) do
    {:noreply, load_local_dir(socket, path)}
  end

  def handle_event("local_open", %{"path" => path, "type" => _file}, socket) do
    case LocalFS.read_file(path) do
      {:ok, data} ->
        {:noreply,
         assign(socket,
           editor_open: true,
           editor_target: :local,
           editor_path: path,
           editor_content: data
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Cannot open local file: #{inspect(reason)}")}
    end
  end

  def handle_event("local_search", %{"value" => q}, socket) do
    {:noreply, assign(socket, :local_filter, q)}
  end

  # ---------------------------------------------------------------------------
  # Remote SFTP Events
  # ---------------------------------------------------------------------------

  def handle_event("remote_navigate", %{"path" => path}, socket) do
    {:noreply, load_remote_dir(socket, path)}
  end

  def handle_event("remote_navigate_up", _params, socket) do
    parent = Path.dirname(socket.assigns.remote_path)
    {:noreply, load_remote_dir(socket, parent)}
  end

  def handle_event("remote_select", %{"path" => path}, socket) do
    selected = if socket.assigns.selected_remote == path, do: nil, else: path
    {:noreply, assign(socket, :selected_remote, selected)}
  end

  def handle_event("remote_open", %{"path" => path, "type" => "directory"}, socket) do
    {:noreply, load_remote_dir(socket, path)}
  end

  def handle_event("remote_open", %{"path" => path, "type" => _file}, socket) do
    pid = socket.assigns.sftp_pid

    case SFTP.read_file(pid, path) do
      {:ok, data} ->
        {:noreply,
         assign(socket,
           editor_open: true,
           editor_target: :remote,
           editor_path: path,
           editor_content: data
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Cannot read remote file: #{inspect(reason)}")}
    end
  end

  def handle_event("remote_search", %{"value" => q}, socket) do
    {:noreply, assign(socket, :remote_filter, q)}
  end

  # ---------------------------------------------------------------------------
  # Bi-Directional Transfers & Drag and Drop
  # ---------------------------------------------------------------------------

  def handle_event("trigger_upload", _params, socket) do
    local_path = socket.assigns.selected_local

    if local_path do
      filename = Path.basename(local_path)
      remote_dest = Path.join(socket.assigns.remote_path, filename)
      execute_upload(socket, local_path, remote_dest, filename)
    else
      {:noreply, assign(socket, :error, "Select a local file first to upload.")}
    end
  end

  def handle_event("trigger_download", _params, socket) do
    remote_path = socket.assigns.selected_remote

    if remote_path do
      filename = Path.basename(remote_path)
      local_dest = Path.join(socket.assigns.local_path, filename)
      execute_download(socket, remote_path, local_dest, filename)
    else
      {:noreply, assign(socket, :error, "Select a remote file first to download.")}
    end
  end

  def handle_event("drop_upload", %{"local_path" => local_path, "filename" => filename}, socket) do
    remote_dest = Path.join(socket.assigns.remote_path, filename)
    execute_upload(socket, local_path, remote_dest, filename)
  end

  def handle_event(
        "drop_download",
        %{"remote_path" => remote_path, "filename" => filename},
        socket
      ) do
    local_dest = Path.join(socket.assigns.local_path, filename)
    execute_download(socket, remote_path, local_dest, filename)
  end

  def handle_event("toggle_hidden", _params, socket) do
    {:noreply, assign(socket, :show_hidden, !socket.assigns.show_hidden)}
  end

  def handle_event("cancel_transfer", %{"id" => id}, socket) do
    TransferManager.cancel_transfer(id)
    {:noreply, refresh_transfers(socket)}
  end

  def handle_event("retry_transfer", %{"id" => id}, socket) do
    TransferManager.retry_transfer(id)
    {:noreply, refresh_transfers(socket)}
  end

  def handle_event("open_rename", %{"target" => target, "path" => path}, socket) do
    {:noreply,
     assign(socket,
       rename_modal: true,
       rename_target: if(target == "local", do: :local, else: :remote),
       rename_path: path,
       rename_name: Path.basename(path)
     )}
  end

  def handle_event("update_rename_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :rename_name, name)}
  end

  def handle_event("confirm_rename", _params, socket) do
    name = String.trim(socket.assigns.rename_name || "")
    path = socket.assigns.rename_path
    dest = Path.join(Path.dirname(path), name)

    result =
      case socket.assigns.rename_target do
        :local -> File.rename(path, dest)
        :remote -> SFTP.rename(socket.assigns.sftp_pid, path, dest)
        _ -> {:error, :invalid}
      end

    socket = assign(socket, rename_modal: false, rename_path: nil, rename_name: "")

    case result do
      :ok ->
        socket =
          if socket.assigns.rename_target == :local do
            load_local_dir(socket, socket.assigns.local_path)
          else
            load_remote_dir(socket, socket.assigns.remote_path)
          end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Rename failed: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # File Editor
  # ---------------------------------------------------------------------------

  def handle_event("editor_content_change", %{"content" => content}, socket) do
    {:noreply, assign(socket, :editor_content, content)}
  end

  def handle_event("save_editor", %{"content" => content}, socket) do
    target = socket.assigns.editor_target
    path = socket.assigns.editor_path
    socket = assign(socket, editor_saving: true, editor_content: content)

    case target do
      :local ->
        case LocalFS.write_file(path, content) do
          :ok ->
            {:noreply,
             socket
             |> assign(editor_saving: false, editor_open: false)
             |> load_local_dir(socket.assigns.local_path)}

          {:error, reason} ->
            {:noreply,
             assign(socket, editor_saving: false, error: "Save local failed: #{inspect(reason)}")}
        end

      :remote ->
        pid = socket.assigns.sftp_pid

        case SFTP.write_file(pid, path, content) do
          :ok ->
            {:noreply,
             socket
             |> assign(editor_saving: false, editor_open: false)
             |> load_remote_dir(socket.assigns.remote_path)}

          {:error, reason} ->
            {:noreply,
             assign(socket, editor_saving: false, error: "Save remote failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("close_editor", _params, socket) do
    {:noreply, assign(socket, editor_open: false, editor_path: nil, editor_content: "")}
  end

  # ---------------------------------------------------------------------------
  # Modals (New Folder, Chmod, Delete, Theme)
  # ---------------------------------------------------------------------------

  def handle_event("open_new_folder", %{"target" => target}, socket) do
    target_atom = if target == "local", do: :local, else: :remote

    {:noreply,
     assign(socket, new_folder_modal: true, new_folder_target: target_atom, new_folder_name: "")}
  end

  def handle_event("update_new_folder_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_folder_name, name)}
  end

  def handle_event("confirm_new_folder", _params, socket) do
    name = String.trim(socket.assigns.new_folder_name)
    target = socket.assigns.new_folder_target

    if name != "" do
      case target do
        :local ->
          dest = Path.join(socket.assigns.local_path, name)
          LocalFS.make_dir(dest)

          {:noreply,
           socket |> assign(new_folder_modal: false) |> load_local_dir(socket.assigns.local_path)}

        :remote ->
          dest = Path.join(socket.assigns.remote_path, name)
          pid = socket.assigns.sftp_pid
          SFTP.make_dir(pid, dest)

          {:noreply,
           socket
           |> assign(new_folder_modal: false)
           |> load_remote_dir(socket.assigns.remote_path)}
      end
    else
      {:noreply, assign(socket, new_folder_modal: false)}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     assign(socket,
       new_folder_modal: false,
       chmod_modal: false,
       delete_modal: false,
       rename_modal: false,
       error: nil
     )}
  end

  def handle_event("open_chmod", %{"path" => path, "perms" => perms}, socket) do
    {:noreply, assign(socket, chmod_modal: true, chmod_entry: path, chmod_octal: perms)}
  end

  def handle_event("update_chmod_octal", %{"octal" => octal}, socket) do
    {:noreply, assign(socket, :chmod_octal, octal)}
  end

  def handle_event("confirm_chmod", _params, socket) do
    path = socket.assigns.chmod_entry
    octal_str = socket.assigns.chmod_octal

    case Integer.parse(octal_str, 8) do
      {_mode, _} ->
        # set mode via command or ssh_sftp
        SSH.exec(socket.assigns.conn, "chmod #{octal_str} \"#{path}\"")

        {:noreply,
         socket |> assign(chmod_modal: false) |> load_remote_dir(socket.assigns.remote_path)}

      :error ->
        {:noreply, assign(socket, :error, "Invalid octal permission: #{octal_str}")}
    end
  end

  def handle_event("request_delete", %{"target" => target, "path" => path}, socket) do
    target_atom = if target == "local", do: :local, else: :remote
    {:noreply, assign(socket, delete_modal: true, delete_target: target_atom, delete_path: path)}
  end

  def handle_event("confirm_delete", _params, socket) do
    target = socket.assigns.delete_target
    path = socket.assigns.delete_path

    case target do
      :local ->
        LocalFS.delete_path(path)

        {:noreply,
         socket |> assign(delete_modal: false) |> load_local_dir(socket.assigns.local_path)}

      :remote ->
        pid = socket.assigns.sftp_pid
        # Attempt file delete first, then directory delete
        case SFTP.delete_file(pid, path) do
          :ok -> :ok
          _ -> SFTP.delete_dir(pid, path)
        end

        {:noreply,
         socket |> assign(delete_modal: false) |> load_remote_dir(socket.assigns.remote_path)}
    end
  end

  def handle_event("clear_error", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  def handle_event("toggle_theme", _params, socket) do
    new_theme = if socket.assigns.theme == "dark", do: "light", else: "dark"

    {:noreply,
     socket |> assign(:theme, new_theme) |> push_event("toggle_theme", %{theme: new_theme})}
  end

  def handle_event("lock_vault", _params, socket) do
    Vault.lock()
    {:noreply, push_navigate(socket, to: "/lock")}
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

        servers = list_all_servers()

        socket =
          socket
          |> put_flash(:info, msg)
          |> assign(:servers, servers)
          |> assign(:online_count, count_online_servers())

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to scan ~/.ssh/config: #{reason}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(%{server_id: nil} = assigns) do
    ~H"""
    <div class="min-h-screen bg-background text-foreground flex flex-col font-sans">
      <.top_navigation
        current_tab={:sftp}
        servers_count={length(@servers)}
        online_count={@online_count}
      />

      <main class="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-8 flex flex-col gap-6">
        <!-- Header Section -->
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-border pb-6">
          <div>
            <h1 class="text-2xl font-bold tracking-tight text-foreground flex items-center gap-2">
              <span>SFTP File Explorer</span>
            </h1>
            <p class="text-sm text-muted-foreground mt-1">
              Browse local and remote filesystems side-by-side, transfer files seamlessly, and manage file permissions.
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
              &lt;/&gt;
            </div>
            <div class="space-y-1">
              <h3 class="text-base font-semibold text-foreground">No Hosts Configured</h3>
              <p class="text-xs text-muted-foreground max-w-sm">
                Add a host manually or import your existing SSH config from ~/.ssh/config to browse files over SFTP.
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
                    href={"/terminal/#{s[:id] || s["id"]}"}
                    class="h-8 px-2.5 bg-secondary hover:bg-secondary/80 border border-border text-foreground font-mono text-xs rounded transition-colors inline-flex items-center"
                  >
                    Terminal
                  </a>
                  <a
                    href={"/sftp/#{s[:id] || s["id"]}"}
                    class="h-8 px-3.5 bg-primary text-primary-foreground hover:bg-primary/90 font-mono text-xs font-medium rounded shadow-sm transition-colors inline-flex items-center gap-1.5"
                  >
                    <span>Open SFTP &rarr;</span>
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
    ~H"""
    <div
      class="flex flex-col h-screen w-screen bg-background text-foreground overflow-hidden select-none font-sans"
      id="dual-pane-sftp"
      phx-hook="DualPaneSFTPHook"
    >
      <!-- Topbar Header -->
      <header class="h-12 flex items-center justify-between px-4 bg-card/90 border-b border-border shrink-0 z-20">
        <div class="flex items-center gap-3 min-w-0">
          <a
            href="/"
            class="text-muted-foreground hover:text-foreground text-xs font-mono transition-colors inline-flex items-center gap-1.5 px-2.5 py-1 rounded bg-secondary hover:bg-secondary/80 border border-border shrink-0"
          >
            &larr; <span class="hidden sm:inline">Hosts</span>
          </a>
          <span class="text-border">|</span>
          <div class="flex items-center gap-2">
            <div class="w-5 h-5 rounded bg-primary text-primary-foreground font-mono font-bold text-[10px] flex items-center justify-center">
              <span>&gt;_</span>
            </div>
            <span class="font-semibold text-xs tracking-tight text-foreground">ssh-client</span>
            <span class="px-1.5 py-0.2 text-[8px] font-mono font-bold tracking-wider rounded bg-destructive/10 text-destructive border border-destructive/20">BETA</span>
          </div>
          <span class="text-border">|</span>
          <span class="text-xs font-mono font-semibold truncate text-foreground">{@server_id}</span>
          <span class="text-muted-foreground text-[11px] font-mono hidden md:inline">Dual-Pane SFTP</span>
        </div>

        <div class="flex items-center gap-2">
          <!-- Terminal Quick Switch -->
          <a
            href={"/terminal/#{@server_id}"}
            class="h-7 px-2.5 bg-primary text-primary-foreground hover:bg-primary/90 font-mono text-xs font-medium rounded shadow-sm inline-flex items-center gap-1.5 transition-colors"
          >
            <span>&gt;_ Terminal</span>
          </a>

          <!-- Logs -->
          <a
            href="/logs"
            class="h-7 px-2.5 bg-secondary hover:bg-secondary/80 border border-border text-muted-foreground hover:text-foreground font-mono text-xs rounded inline-flex items-center transition-colors"
          >
            Logs
          </a>
        </div>
      </header>

      <!-- Global Error Notification Banner -->
      <%= if @error do %>
        <div class="bg-destructive/10 border-b border-destructive/20 px-4 py-2 flex items-center justify-between text-xs font-mono text-destructive z-30 shrink-0">
          <div class="flex items-center gap-2 min-w-0">
            <span class="w-2 h-2 rounded-full bg-destructive animate-pulse shrink-0"></span>
            <span class="font-bold shrink-0">Notice:</span>
            <span class="truncate">{@error}</span>
          </div>
          <button
            phx-click="clear_error"
            class="text-destructive hover:text-destructive/80 font-bold px-2 py-0.5 rounded hover:bg-destructive/10 shrink-0"
            title="Dismiss"
          >
            &times;
          </button>
        </div>
      <% end %>

      <!-- Main Dual-Pane Workspace -->
      <div class="flex-1 flex min-h-0 bg-background relative">
        <!-- LEFT PANE: LOCAL FILESYSTEM -->
        <section
          class="flex-1 flex flex-col border-r border-border min-w-0"
          data-drop-side="local"
          data-drop-path={@local_path}
        >
          <!-- Local Pane Header & Path Bar -->
          <div class="p-3 bg-card/50 border-b border-border flex flex-col gap-2">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2 font-mono text-xs font-semibold text-foreground">
                <span class="w-2 h-2 rounded-full bg-emerald-500"></span>
                <span>LOCAL SYSTEM</span>
              </div>
              <div class="flex items-center gap-1">
                <button
                  phx-click="toggle_hidden"
                  class="px-2 py-0.5 text-[11px] font-mono bg-secondary hover:bg-secondary/80 border border-border rounded text-secondary-foreground transition-colors"
                >
                  {if Map.get(assigns, :show_hidden, false), do: "Hide dotfiles", else: "Show hidden"}
                </button>
                <button
                  phx-click="open_new_folder"
                  phx-value-target="local"
                  class="px-2 py-0.5 text-[11px] font-mono bg-secondary hover:bg-secondary/80 border border-border rounded text-secondary-foreground transition-colors"
                >
                  + New Folder
                </button>
              </div>
            </div>

            <!-- Path Bar & Quick Jumps -->
            <div class="flex items-center gap-1.5">
              <button
                phx-click="local_navigate_up"
                class="px-2 py-1 bg-secondary hover:bg-secondary/80 border border-border rounded text-xs font-mono text-secondary-foreground transition-colors"
                title="Up One Directory"
              >
                &uarr; Up
              </button>
              <form phx-submit="local_navigate" class="flex-1 min-w-0">
                <input
                  type="text"
                  name="path"
                  value={@local_path}
                  class="w-full bg-background border border-border rounded px-2.5 py-1 text-xs font-mono text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
                />
              </form>
            </div>

            <!-- Filter Search -->
            <input
              type="text"
              placeholder="Search local files..."
              phx-keyup="local_search"
              value={@local_filter}
              class="w-full bg-background border border-border rounded px-2 py-0.5 text-[11px] font-mono text-muted-foreground focus:text-foreground focus:outline-none"
            />
          </div>

          <!-- Local File Table -->
          <div class="flex-1 overflow-y-auto font-mono text-xs">
            <table class="w-full border-collapse">
              <thead class="sticky top-0 bg-card border-b border-border text-[10px] text-muted-foreground uppercase tracking-wider">
                <tr>
                  <th class="py-1.5 px-3 text-left">Name</th>
                  <th class="py-1.5 px-3 text-right w-20">Size</th>
                  <th class="py-1.5 px-3 text-right w-28 hidden sm:table-cell">Modified</th>
                  <th class="py-1.5 px-2 text-center w-10">Act</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-border">
                <%= for entry <- filter_entries(@local_entries, @local_filter, Map.get(assigns, :show_hidden, false)) do %>
                  <tr
                    class={"hover:bg-muted/40 cursor-pointer transition-colors #{if @selected_local == entry.path, do: "bg-muted border-l-2 border-primary", else: ""}"}
                    phx-click="local_select"
                    phx-value-path={entry.path}
                    draggable="true"
                    data-drag-path={entry.path}
                    data-drag-side="local"
                    data-drag-name={entry.name}
                    data-drag-type={to_string(entry.type)}
                  >
                    <td
                      class="py-1.5 px-3 flex items-center gap-2 truncate"
                      phx-click="local_open"
                      phx-value-path={entry.path}
                      phx-value-type={to_string(entry.type)}
                    >
                      <span class={
                        if entry.type == :directory,
                          do: "text-amber-500 font-bold",
                          else: "text-muted-foreground"
                      }>
                        {if entry.type == :directory, do: "[DIR]", else: "[FILE]"}
                      </span>
                      <span class={"truncate #{if entry.type == :directory, do: "font-semibold text-foreground", else: "text-muted-foreground"}"}>
                        {entry.name}
                      </span>
                    </td>
                    <td class="py-1.5 px-3 text-right text-[11px] text-muted-foreground">
                      {if entry.type == :directory, do: "-", else: LocalFS.format_size(entry.size)}
                    </td>
                    <td class="py-1.5 px-3 text-right text-[10px] text-muted-foreground hidden sm:table-cell">
                      {format_mtime(entry.mtime)}
                    </td>
                    <td class="py-1.5 px-2 text-center">
                      <button
                        phx-click="open_rename"
                        phx-value-target="local"
                        phx-value-path={entry.path}
                        class="text-muted-foreground hover:text-foreground text-[10px] mr-1"
                        title="Rename"
                      >
                        Ren
                      </button>
                      <button
                        phx-click="request_delete"
                        phx-value-target="local"
                        phx-value-path={entry.path}
                        class="text-muted-foreground hover:text-destructive text-[10px]"
                        title="Delete"
                      >
                        &times;
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </section>

        <!-- CENTER CONTROLS (Upload & Download Actions) -->
        <div class="w-12 bg-card/50 border-r border-border flex flex-col items-center justify-center gap-4 shrink-0 z-10">
          <button
            phx-click="trigger_upload"
            class="w-8 h-8 rounded-lg bg-primary text-primary-foreground hover:bg-primary/90 flex items-center justify-center font-bold text-sm shadow transition-all hover:scale-105"
            title="Upload Selected to Remote ->"
          >
            &rarr;
          </button>
          <button
            phx-click="trigger_download"
            class="w-8 h-8 rounded-lg bg-secondary hover:bg-secondary/80 border border-border text-secondary-foreground flex items-center justify-center font-bold text-sm shadow transition-all hover:scale-105"
            title="<- Download Selected to Local"
          >
            &larr;
          </button>
        </div>

        <!-- RIGHT PANE: REMOTE SFTP FILESYSTEM -->
        <section
          class="flex-1 flex flex-col min-w-0"
          data-drop-side="remote"
          data-drop-path={@remote_path}
        >
          <!-- Remote Pane Header & Path Bar -->
          <div class="p-3 bg-card/50 border-b border-border flex flex-col gap-2">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2 font-mono text-xs font-semibold text-foreground">
                <span class="w-2 h-2 rounded-full bg-cyan-500 animate-pulse"></span>
                <span>REMOTE SERVER {if @server,
                  do: "(#{@server.user}@#{@server.host})",
                  else: "(#{@server_id})"}</span>
              </div>
              <div class="flex items-center gap-1">
                <button
                  phx-click="open_new_folder"
                  phx-value-target="remote"
                  class="px-2 py-0.5 text-[11px] font-mono bg-secondary hover:bg-secondary/80 border border-border rounded text-secondary-foreground transition-colors"
                >
                  + New Folder
                </button>
              </div>
            </div>

            <!-- Path Bar & Quick Jumps -->
            <div class="flex items-center gap-1.5">
              <button
                phx-click="remote_navigate_up"
                class="px-2 py-1 bg-secondary hover:bg-secondary/80 border border-border rounded text-xs font-mono text-secondary-foreground transition-colors"
                title="Up One Directory"
              >
                &uarr; Up
              </button>
              <form phx-submit="remote_navigate" class="flex-1 min-w-0">
                <input
                  type="text"
                  name="path"
                  value={@remote_path}
                  class="w-full bg-background border border-border rounded px-2.5 py-1 text-xs font-mono text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
                />
              </form>
            </div>

            <!-- Quick Path Bookmarks -->
            <div class="flex items-center gap-1.5 text-[10px] font-mono text-muted-foreground overflow-x-auto pb-0.5">
              <span>Quick:</span>
              <button
                phx-click="remote_navigate"
                phx-value-path="/var/www"
                class="hover:text-foreground"
              >/var/www</button>
              <span>&bull;</span>
              <button phx-click="remote_navigate" phx-value-path="/etc" class="hover:text-foreground">/etc</button>
              <span>&bull;</span>
              <button phx-click="remote_navigate" phx-value-path="/tmp" class="hover:text-foreground">/tmp</button>
              <span>&bull;</span>
              <button phx-click="remote_navigate" phx-value-path="/root" class="hover:text-foreground">/root</button>
            </div>

            <!-- Filter Search -->
            <input
              type="text"
              placeholder="Search remote files..."
              phx-keyup="remote_search"
              value={@remote_filter}
              class="w-full bg-background border border-border rounded px-2 py-0.5 text-[11px] font-mono text-muted-foreground focus:text-foreground focus:outline-none"
            />
          </div>

          <!-- Remote File Table -->
          <div class="flex-1 overflow-y-auto font-mono text-xs">
            <%= if @remote_loading do %>
              <div class="p-8 text-center text-muted-foreground font-mono text-xs">
                Connecting to remote SFTP channel...
              </div>
            <% else %>
              <table class="w-full border-collapse">
                <thead class="sticky top-0 bg-card border-b border-border text-[10px] text-muted-foreground uppercase tracking-wider">
                  <tr>
                    <th class="py-1.5 px-3 text-left">Name</th>
                    <th class="py-1.5 px-3 text-right w-20">Size</th>
                    <th class="py-1.5 px-3 text-left w-20 hidden md:table-cell">Perms</th>
                    <th class="py-1.5 px-3 text-right w-28 hidden sm:table-cell">Modified</th>
                    <th class="py-1.5 px-2 text-center w-10">Act</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-border">
                  <%= for entry <- filter_entries(@remote_entries, @remote_filter, Map.get(assigns, :show_hidden, false)) do %>
                    <tr
                      class={"hover:bg-muted/40 cursor-pointer transition-colors #{if @selected_remote == entry.path, do: "bg-muted border-l-2 border-primary", else: ""}"}
                      phx-click="remote_select"
                      phx-value-path={entry.path}
                      draggable="true"
                      data-drag-path={entry.path}
                      data-drag-side="remote"
                      data-drag-name={entry.name}
                      data-drag-type={to_string(entry.type)}
                    >
                      <td
                        class="py-1.5 px-3 flex items-center gap-2 truncate"
                        phx-click="remote_open"
                        phx-value-path={entry.path}
                        phx-value-type={to_string(entry.type)}
                      >
                        <span class={
                          if entry.type == :directory,
                            do: "text-cyan-500 font-bold",
                            else: "text-muted-foreground"
                        }>
                          {if entry.type == :directory, do: "[DIR]", else: "[FILE]"}
                        </span>
                        <span class={"truncate #{if entry.type == :directory, do: "font-semibold text-foreground", else: "text-muted-foreground"}"}>
                          {entry.name}
                        </span>
                      </td>
                      <td class="py-1.5 px-3 text-right text-[11px] text-muted-foreground">
                        {if entry.type == :directory, do: "-", else: SFTP.format_size(entry.size)}
                      </td>
                      <td
                        class="py-1.5 px-3 text-left text-[10px] text-muted-foreground hover:text-foreground hidden md:table-cell"
                        phx-click="open_chmod"
                        phx-value-path={entry.path}
                        phx-value-perms={entry.permissions}
                      >
                        {entry.permissions}
                      </td>
                      <td class="py-1.5 px-3 text-right text-[10px] text-muted-foreground hidden sm:table-cell">
                        {format_mtime(entry.mtime)}
                      </td>
                      <td class="py-1.5 px-2 text-center">
                        <button
                          phx-click="open_rename"
                          phx-value-target="remote"
                          phx-value-path={entry.path}
                          class="text-muted-foreground hover:text-foreground text-[10px] mr-1"
                          title="Rename"
                        >
                          Ren
                        </button>
                        <button
                          phx-click="request_delete"
                          phx-value-target="remote"
                          phx-value-path={entry.path}
                          class="text-muted-foreground hover:text-destructive text-[10px]"
                          title="Delete"
                        >
                          &times;
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </section>
      </div>

      <!-- BOTTOM TRANSFER QUEUE DOCK -->
      <footer class="h-14 bg-card border-t border-border px-4 flex items-center justify-between font-mono text-xs shrink-0 z-20">
        <div class="flex items-center gap-3 min-w-0 flex-1">
          <span class="text-[10px] uppercase font-bold text-muted-foreground tracking-wider shrink-0">Queue:</span>
          <%= if @active_transfer do %>
            <div class="flex items-center gap-3 min-w-0 flex-1 max-w-xl">
              <span class="text-foreground text-xs truncate font-semibold">{@active_transfer.filename}</span>
              <div class="flex-1 h-2 bg-muted rounded-full overflow-hidden border border-border">
                <div
                  class="h-full bg-primary transition-all duration-200"
                  style={"width: #{@transfer_progress}%"}
                >
                </div>
              </div>
              <span class="text-foreground text-xs shrink-0 font-medium">{@transfer_progress}%</span>
              <button
                phx-click="cancel_transfer"
                phx-value-id={@active_transfer.id}
                class="text-[10px] font-mono text-destructive"
              >Cancel</button>
              <%= if @active_transfer.status == :failed do %>
                <button
                  phx-click="retry_transfer"
                  phx-value-id={@active_transfer.id}
                  class="text-[10px] font-mono text-foreground"
                >Retry</button>
              <% end %>
            </div>
          <% else %>
            <span class="text-muted-foreground text-xs">Idle — Drag and drop files between panes or click Transfer arrows</span>
          <% end %>
        </div>

        <div class="flex items-center gap-4 text-[11px] text-muted-foreground">
          <span>{length(@local_entries)} local items</span>
          <span>&bull;</span>
          <span>{length(@remote_entries)} remote items</span>
        </div>
      </footer>

      <!-- INLINE CODE / CONFIG EDITOR MODAL -->
      <%= if @editor_open do %>
        <div class="fixed inset-0 z-50 bg-black/70 backdrop-blur-sm flex items-center justify-center p-6">
          <div class="w-full max-w-4xl h-[80vh] bg-card border border-border rounded-xl flex flex-col shadow-2xl overflow-hidden font-mono">
            <div class="px-5 py-3 border-b border-border flex items-center justify-between bg-muted/40">
              <div class="flex items-center gap-2">
                <span class="text-xs font-bold text-foreground">{String.upcase(
                  to_string(@editor_target)
                )} FILE:</span>
                <span class="text-xs text-foreground truncate">{@editor_path}</span>
              </div>
              <div class="flex items-center gap-2">
                <button
                  phx-click="save_editor"
                  phx-value-content={@editor_content}
                  disabled={@editor_saving}
                  class="px-3 py-1 bg-primary hover:bg-primary/90 text-primary-foreground text-xs font-medium rounded-md transition-colors shadow"
                >
                  {if @editor_saving, do: "Saving...", else: "Save"}
                </button>
                <button
                  phx-click="close_editor"
                  class="px-3 py-1 bg-secondary hover:bg-secondary/80 text-secondary-foreground text-xs rounded-md"
                >
                  Close
                </button>
              </div>
            </div>
            <div class="flex-1 p-4 bg-background">
              <textarea
                name="content"
                phx-change="editor_content_change"
                class="w-full h-full bg-transparent text-foreground font-mono text-xs focus:outline-none resize-none"
              ><%= @editor_content %></textarea>
            </div>
          </div>
        </div>
      <% end %>

      <!-- NEW FOLDER MODAL -->
      <%= if @new_folder_modal do %>
        <div class="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4">
          <div class="bg-card border border-border rounded-xl p-6 w-full max-w-md space-y-4 shadow-2xl font-mono">
            <h3 class="text-sm font-bold text-foreground">
              Create Directory on {String.upcase(to_string(@new_folder_target))}
            </h3>
            <input
              type="text"
              placeholder="folder_name"
              phx-keyup="update_new_folder_name"
              value={@new_folder_name}
              class="w-full bg-background border border-border rounded-lg px-3 py-2 text-xs font-mono text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
              autofocus
            />
            <div class="flex justify-end gap-2">
              <button
                phx-click="close_modal"
                class="px-3 py-1.5 text-xs text-muted-foreground hover:text-foreground"
              >Cancel</button>
              <button
                phx-click="confirm_new_folder"
                class="px-4 py-1.5 text-xs bg-primary text-primary-foreground hover:bg-primary/90 rounded-lg font-medium"
              >Create</button>
            </div>
          </div>
        </div>
      <% end %>

      <%= if Map.get(assigns, :rename_modal, false) do %>
        <div class="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4">
          <div class="bg-card border border-border rounded-xl p-6 w-full max-w-md space-y-4 shadow-2xl font-mono">
            <h3 class="text-sm font-bold text-foreground">Rename</h3>
            <input
              type="text"
              phx-keyup="update_rename_name"
              value={@rename_name}
              class="w-full bg-background border border-border rounded-lg px-3 py-2 text-xs font-mono text-foreground focus:outline-none"
              autofocus
            />
            <div class="flex justify-end gap-2">
              <button phx-click="close_modal" class="px-3 py-1.5 text-xs text-muted-foreground">Cancel</button>
              <button
                phx-click="confirm_rename"
                class="px-4 py-1.5 text-xs bg-primary text-primary-foreground rounded-lg"
              >Rename</button>
            </div>
          </div>
        </div>
      <% end %>

      <!-- CHMOD MODAL -->
      <%= if @chmod_modal do %>
        <div class="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4">
          <div class="bg-card border border-border rounded-xl p-6 w-full max-w-md space-y-4 shadow-2xl font-mono">
            <h3 class="text-sm font-bold text-foreground">Change Remote Permissions (chmod)</h3>
            <p class="text-xs text-muted-foreground truncate">{@chmod_entry}</p>
            <div class="space-y-2">
              <label class="text-[11px] text-muted-foreground">Octal Notation (e.g. 0755, 0644):</label>
              <input
                type="text"
                phx-keyup="update_chmod_octal"
                value={@chmod_octal}
                class="w-full bg-background border border-border rounded-lg px-3 py-2 text-xs font-mono text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
              />
            </div>
            <div class="flex justify-end gap-2">
              <button
                phx-click="close_modal"
                class="px-3 py-1.5 text-xs text-muted-foreground hover:text-foreground"
              >Cancel</button>
              <button
                phx-click="confirm_chmod"
                class="px-4 py-1.5 text-xs bg-primary text-primary-foreground hover:bg-primary/90 rounded-lg font-medium"
              >Apply</button>
            </div>
          </div>
        </div>
      <% end %>

      <!-- DELETE MODAL -->
      <%= if @delete_modal do %>
        <div class="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4">
          <div class="bg-card border border-destructive/30 rounded-xl p-6 w-full max-w-md space-y-4 shadow-2xl font-mono">
            <h3 class="text-sm font-bold text-destructive">Confirm Deletion</h3>
            <p class="text-xs text-muted-foreground break-all">
              Are you sure you want to delete this {@delete_target} item?<br /><strong class="text-foreground">{@delete_path}</strong>
            </p>
            <div class="flex justify-end gap-2">
              <button
                phx-click="close_modal"
                class="px-3 py-1.5 text-xs text-muted-foreground hover:text-foreground"
              >Cancel</button>
              <button
                phx-click="confirm_delete"
                class="px-4 py-1.5 text-xs bg-destructive text-destructive-foreground hover:bg-destructive/90 rounded-lg font-medium"
              >Delete</button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers & Loaders
  # ---------------------------------------------------------------------------

  defp load_local_dir(socket, path) do
    case LocalFS.list_dir(path) do
      {:ok, entries} ->
        assign(socket,
          local_path: path,
          local_entries: entries,
          local_loading: false,
          selected_local: nil
        )

      {:error, _} ->
        assign(socket, local_loading: false, error: "Cannot access local directory: #{path}")
    end
  end

  defp load_remote_dir(socket, path) do
    pid = socket.assigns.sftp_pid

    if pid && Process.alive?(pid) do
      case SFTP.list_dir(pid, path) do
        {:ok, entries} ->
          assign(socket,
            remote_path: path,
            remote_entries: entries,
            remote_loading: false,
            selected_remote: nil
          )

        {:error, reason} ->
          assign(socket,
            remote_loading: false,
            error: "Cannot read remote path: #{inspect(reason)}"
          )
      end
    else
      assign(socket, remote_loading: false)
    end
  end

  defp execute_upload(socket, local_path, remote_dest, filename) do
    pid = socket.assigns.sftp_pid

    case TransferManager.queue_upload(pid, local_path, remote_dest,
           filename: filename,
           caller: self(),
           server: socket.assigns.server
         ) do
      {:ok, _id} ->
        {:noreply, refresh_transfers(socket) |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Upload failed to queue: #{inspect(reason)}")}
    end
  end

  defp execute_download(socket, remote_path, local_dest, filename) do
    pid = socket.assigns.sftp_pid

    case TransferManager.queue_download(pid, remote_path, local_dest,
           filename: filename,
           caller: self(),
           server: socket.assigns.server
         ) do
      {:ok, _id} ->
        {:noreply, refresh_transfers(socket) |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Download failed to queue: #{inspect(reason)}")}
    end
  end

  defp refresh_transfers(socket) do
    transfers = TransferManager.list_transfers()
    active = Enum.find(transfers, &(&1.status in [:queued, :transferring]))
    progress = if active, do: active.progress || 0, else: socket.assigns[:transfer_progress] || 0

    assign(socket, transfers: transfers, active_transfer: active, transfer_progress: progress)
  end

  def filter_entries(entries, filter, show_hidden \\ true) do
    entries
    |> Enum.reject(fn e ->
      hidden? = String.starts_with?(e.name || "", ".")
      hidden? and not show_hidden
    end)
    |> then(fn list ->
      if filter in [nil, ""] do
        list
      else
        q = String.downcase(filter)
        Enum.filter(list, fn e -> String.contains?(String.downcase(e.name || ""), q) end)
      end
    end)
  end

  def format_mtime({{year, month, day}, {hour, minute, _sec}}) do
    "#{year}-#{pad(month)}-#{pad(day)} #{pad(hour)}:#{pad(minute)}"
  end

  def format_mtime(_), do: "-"

  def pad(n) when n < 10, do: "0#{n}"
  def pad(n), do: "#{n}"

  def resolve_server_struct(server_id) do
    try do
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
          resolve_server_from_config(server_id)
      end
    catch
      _, _ ->
        resolve_server_from_config(server_id)
    end
  end

  defp resolve_server_from_config(id) do
    case Config.load_config() do
      {:ok, cfg} ->
        Enum.find(cfg.servers, &(&1.id == id))

      _ ->
        case Config.load_file(Config.default_config_path()) do
          {:ok, cfg} -> Enum.find(cfg.servers, &(&1.id == id))
          _ -> nil
        end
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
end
