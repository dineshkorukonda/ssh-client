defmodule SSHClientWeb.SFTPLive do
  @moduledoc """
  Interactive SFTP remote file explorer LiveView with directory navigation,
  file upload/download triggers, and inline configuration editor.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}

  alias SSHClient.ActivityLog
  alias SSHClient.Config
  alias SSHClient.Config.Server
  alias SSHClient.ServerManager
  alias SSHClient.SFTP
  alias SSHClient.SSH
  alias SSHClient.Vault

  @impl true
  def mount(%{"id" => server_id}, _session, socket) do
    if not Vault.unlocked?() do
      {:ok, push_navigate(socket, to: "/lock")}
    else
      server = resolve_server_struct(server_id)

      socket =
        socket
        |> assign(:page_title, "SFTP — #{server_id}")
        |> assign(:server_id, server_id)
        |> assign(:server, server)
        |> assign(:conn, nil)
        |> assign(:sftp_pid, nil)
        |> assign(:current_path, "/root")
        |> assign(:entries, [])
        |> assign(:loading, true)
        |> assign(:filter, "")
        |> assign(:error, nil)
        |> assign(:editing_file, nil)
        |> assign(:file_content, nil)
        |> assign(:new_folder_modal, false)
        |> assign(:new_folder_name, "")

      if connected?(socket) do
        send(self(), :connect_sftp)
      end

      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:connect_sftp, socket) do
    server = socket.assigns.server

    if is_nil(server) do
      {:noreply, assign(socket, loading: false, error: "Server #{socket.assigns.server_id} not found.")}
    else
      case SSH.connect(server) do
        {:ok, conn} ->
          case SFTP.start_channel(conn) do
            {:ok, sftp_pid} ->
              # Try navigating to home or root
              start_path = if server.user == "root", do: "/root", else: "/home/#{server.user}"
              socket =
                socket
                |> assign(conn: conn, sftp_pid: sftp_pid, current_path: start_path)
                |> load_directory(start_path)

              {:noreply, socket}

            {:error, reason} ->
              {:noreply, assign(socket, loading: false, error: "Failed to open SFTP channel: #{inspect(reason)}")}
          end

        {:error, reason} ->
          {:noreply, assign(socket, loading: false, error: "SSH connection failed: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("navigate", %{"path" => path}, socket) do
    {:noreply, load_directory(socket, path)}
  end

  def handle_event("navigate_up", _params, socket) do
    parent = Path.dirname(socket.assigns.current_path)
    {:noreply, load_directory(socket, parent)}
  end

  def handle_event("search", %{"value" => q}, socket) do
    {:noreply, assign(socket, :filter, q)}
  end

  def handle_event("open_entry", %{"path" => path, "type" => "directory"}, socket) do
    {:noreply, load_directory(socket, path)}
  end

  def handle_event("open_entry", %{"path" => path, "type" => _file}, socket) do
    pid = socket.assigns.sftp_pid
    case SFTP.read_file(pid, path) do
      {:ok, data} ->
        # Limit preview to UTF-8 text files up to 1MB
        if byte_size(data) <= 1_000_000 and String.valid?(data) do
          {:noreply, assign(socket, editing_file: path, file_content: data, error: nil)}
        else
          {:noreply, assign(socket, editing_file: path, file_content: "[Binary or large file (>1MB). Direct viewing disabled.]", error: nil)}
        end

      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to read file: #{inspect(reason)}")}
    end
  end

  def handle_event("close_editor", _params, socket) do
    {:noreply, assign(socket, editing_file: nil, file_content: nil)}
  end

  def handle_event("save_file", %{"content" => content}, socket) do
    pid = socket.assigns.sftp_pid
    path = socket.assigns.editing_file

    if pid && path do
      case SFTP.write_file(pid, path, content) do
        :ok ->
          ActivityLog.info(socket.assigns.server_id, "Saved remote file #{path}")
          {:noreply, assign(socket, editing_file: nil, file_content: nil) |> load_directory(socket.assigns.current_path)}

        {:error, reason} ->
          {:noreply, assign(socket, error: "Failed to save file: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_entry", %{"path" => path, "type" => type}, socket) do
    pid = socket.assigns.sftp_pid
    res = if type == "directory", do: SFTP.delete_dir(pid, path), else: SFTP.delete_file(pid, path)

    case res do
      :ok ->
        ActivityLog.info(socket.assigns.server_id, "Deleted remote #{type} #{path}")
        {:noreply, load_directory(socket, socket.assigns.current_path)}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("open_new_folder", _params, socket) do
    {:noreply, assign(socket, new_folder_modal: true, new_folder_name: "")}
  end

  def handle_event("close_new_folder", _params, socket) do
    {:noreply, assign(socket, new_folder_modal: false)}
  end

  def handle_event("create_folder", %{"name" => name}, socket) do
    name = String.trim(name || "")
    if name != "" do
      new_path = Path.join(socket.assigns.current_path, name)
      case SFTP.make_dir(socket.assigns.sftp_pid, new_path) do
        :ok ->
          {:noreply, socket |> assign(new_folder_modal: false) |> load_directory(socket.assigns.current_path)}

        {:error, reason} ->
          {:noreply, assign(socket, error: "Failed to create directory: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, new_folder_modal: false)}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:sftp_pid], do: SFTP.stop_channel(pid)
    if conn = socket.assigns[:conn], do: SSH.close(conn)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    filtered_entries =
      if assigns.filter == "" do
        assigns.entries
      else
        q = String.downcase(assigns.filter)
        Enum.filter(assigns.entries, fn e -> String.contains?(String.downcase(e.name), q) end)
      end

    assigns = assign(assigns, :filtered_entries, filtered_entries)

    ~H"""
    <div class="flex flex-col h-screen w-screen bg-[#050505] overflow-hidden select-none font-sans">
      <!-- Topbar -->
      <header class="h-12 flex items-center justify-between px-4 bg-[#0a0a0a] border-b border-[#1f1f1f] shrink-0 z-20">
        <div class="flex items-center gap-2.5 min-w-0">
          <a
            href="/"
            class="text-zinc-400 hover:text-white text-xs font-mono transition-colors inline-flex items-center gap-1 px-2.5 py-1 rounded bg-[#141414] hover:bg-[#202020] border border-[#27272a] shrink-0"
          >
            &larr; <span class="hidden sm:inline">Hosts</span>
          </a>
          <span class="text-zinc-700">|</span>
          <span class="text-white text-xs font-mono font-semibold truncate"><%= @server_id %></span>
          <span class="px-1.5 py-0.5 text-[9px] font-mono font-semibold uppercase tracking-wider rounded bg-red-500/10 text-red-400 border border-red-500/20">BETA</span>
          <span class="text-zinc-600 text-xs font-mono">SFTP Explorer</span>
        </div>

        <div class="flex items-center gap-2">
          <a
            href={"/terminal/#{@server_id}"}
            class="h-7 px-2.5 bg-blue-600 hover:bg-blue-500 text-white text-xs font-mono font-medium rounded-md transition-colors shadow-sm inline-flex items-center"
          >
            Terminal
          </a>
          <button
            phx-click="open_new_folder"
            class="h-7 px-2.5 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-300 hover:text-white text-xs font-mono rounded-md transition-colors"
          >
            + New Folder
          </button>
          <a
            href="/logs"
            class="h-7 px-2.5 bg-[#141414] hover:bg-[#202020] border border-[#27272a] hover:border-zinc-500 text-zinc-400 hover:text-zinc-200 text-xs font-mono rounded-md transition-colors inline-flex items-center"
          >
            Logs
          </a>
        </div>
      </header>

      <!-- Path & Controls bar -->
      <div class="h-10 px-4 bg-[#0e0e10] border-b border-[#1f1f1f] flex items-center justify-between gap-3 shrink-0">
        <div class="flex items-center gap-2 flex-1 min-w-0">
          <button
            phx-click="navigate_up"
            class="px-2 py-0.5 bg-[#18181b] hover:bg-[#222] border border-[#27272a] text-zinc-400 hover:text-white text-xs font-mono rounded transition-colors"
            title="Parent Directory"
          >
            ..
          </button>
          <div class="flex items-center gap-1 font-mono text-xs text-zinc-300 overflow-x-auto truncate">
            <span class="text-zinc-500">Path:</span>
            <span class="text-blue-400 font-semibold select-text"><%= @current_path %></span>
          </div>
        </div>

        <div class="flex items-center gap-2 shrink-0">
          <input
            type="text"
            placeholder="Filter directory..."
            value={@filter}
            phx-keyup="search"
            phx-debounce="100"
            name="value"
            class="h-6 px-2 bg-[#18181b] border border-[#27272a] rounded text-xs font-mono text-zinc-300 placeholder-zinc-600 focus:outline-none focus:border-blue-500 w-36"
          />
          <button
            phx-click="navigate"
            phx-value-path={@current_path}
            class="h-6 px-2 bg-[#18181b] hover:bg-[#222] border border-[#27272a] text-zinc-400 hover:text-white text-xs font-mono rounded transition-colors"
          >
            Refresh
          </button>
        </div>
      </div>

      <%= if @error do %>
        <div class="px-4 py-2 bg-red-500/10 border-b border-red-500/20 text-red-400 text-xs font-mono flex items-center justify-between">
          <span><%= @error %></span>
          <button phx-click="navigate" phx-value-path={@current_path} class="underline text-red-300">Dismiss</button>
        </div>
      <% end %>

      <!-- File Table -->
      <div class="flex-1 overflow-auto">
        <%= if @loading do %>
          <div class="flex flex-col items-center justify-center h-64 gap-2 text-zinc-600 font-mono text-xs">
            <span class="animate-pulse">Connecting to SFTP channel...</span>
          </div>
        <% else %>
          <%= if @filtered_entries == [] do %>
            <div class="flex flex-col items-center justify-center h-64 text-zinc-600 font-mono text-xs">
              <span>Directory is empty</span>
            </div>
          <% else %>
            <table class="w-full text-left border-collapse text-xs font-mono">
              <thead>
                <tr class="border-b border-[#18181b] text-zinc-500 uppercase tracking-wider text-[10px]">
                  <th class="px-4 py-2.5">Name</th>
                  <th class="px-4 py-2.5 w-24">Type</th>
                  <th class="px-4 py-2.5 w-28">Size</th>
                  <th class="px-4 py-2.5 w-24">Mode</th>
                  <th class="px-4 py-2.5 text-right w-32">Actions</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-[#121214]">
                <%= for entry <- @filtered_entries do %>
                  <tr class="hover:bg-white/[0.02] group transition-colors">
                    <td class="px-4 py-2 text-zinc-200">
                      <div
                        phx-click="open_entry"
                        phx-value-path={entry.path}
                        phx-value-type={to_string(entry.type)}
                        class={["cursor-pointer flex items-center gap-2", if(entry.type == :directory, do: "text-blue-400 hover:text-blue-300 font-medium", else: "text-zinc-300 hover:text-white")]}
                      >
                        <span class="text-[10px] text-zinc-600 select-none">
                          <%= if entry.type == :directory, do: "[DIR]", else: "[FILE]" %>
                        </span>
                        <span class="truncate"><%= entry.name %></span>
                      </div>
                    </td>
                    <td class="px-4 py-2 text-zinc-500">
                      <%= entry.type %>
                    </td>
                    <td class="px-4 py-2 text-zinc-400">
                      <%= if entry.type == :directory, do: "-", else: format_bytes(entry.size) %>
                    </td>
                    <td class="px-4 py-2 text-zinc-600">
                      <%= entry.permissions %>
                    </td>
                    <td class="px-4 py-2 text-right">
                      <div class="flex items-center justify-end gap-1.5 opacity-80 group-hover:opacity-100">
                        <%= if entry.type != :directory do %>
                          <button
                            phx-click="open_entry"
                            phx-value-path={entry.path}
                            phx-value-type="regular"
                            class="px-2 py-0.5 bg-[#18181b] hover:bg-[#27272a] text-zinc-300 hover:text-white rounded transition-colors"
                            title="View / Edit Text File"
                          >
                            Edit
                          </button>
                        <% end %>
                        <button
                          phx-click="delete_entry"
                          phx-value-path={entry.path}
                          phx-value-type={to_string(entry.type)}
                          data-confirm={"Delete #{entry.name}?"}
                          class="px-2 py-0.5 bg-red-500/10 hover:bg-red-500/20 text-red-400 hover:text-red-300 rounded transition-colors"
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
        <% end %>
      </div>

      <!-- Inline Text Editor Modal -->
      <%= if @editing_file do %>
        <div class="fixed inset-0 bg-black/80 backdrop-blur-sm z-50 flex items-center justify-center p-4">
          <div class="bg-[#0e0e11] border border-[#27272a] rounded-xl w-full max-w-4xl h-[80vh] flex flex-col shadow-2xl overflow-hidden font-mono">
            <!-- Modal Header -->
            <div class="h-10 px-4 bg-[#141418] border-b border-[#27272a] flex items-center justify-between shrink-0">
              <div class="flex items-center gap-2 truncate">
                <span class="text-xs font-semibold text-white">Editing:</span>
                <span class="text-xs text-blue-400 truncate"><%= @editing_file %></span>
              </div>
              <button
                phx-click="close_editor"
                class="text-zinc-500 hover:text-white text-xs px-2 py-0.5 rounded hover:bg-[#202020] transition-colors"
              >
                Close
              </button>
            </div>

            <!-- Editor Form -->
            <form phx-submit="save_file" class="flex-1 flex flex-col min-h-0">
              <textarea
                name="content"
                class="flex-1 w-full p-4 bg-[#08080a] text-zinc-200 font-mono text-xs focus:outline-none resize-none overflow-auto border-none leading-relaxed select-text"
                spellcheck="false"
              ><%= @file_content %></textarea>

              <div class="h-11 px-4 bg-[#141418] border-t border-[#27272a] flex items-center justify-between shrink-0">
                <span class="text-[11px] text-zinc-500">Press Save to write changes directly to remote server.</span>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    phx-click="close_editor"
                    class="px-3 py-1 bg-[#202024] hover:bg-[#2c2c32] text-zinc-300 text-xs rounded transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="px-4 py-1 bg-blue-600 hover:bg-blue-500 text-white text-xs font-medium rounded transition-colors shadow-sm"
                  >
                    Save Changes
                  </button>
                </div>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <!-- New Folder Modal -->
      <%= if @new_folder_modal do %>
        <div class="fixed inset-0 bg-black/70 backdrop-blur-sm z-50 flex items-center justify-center p-4">
          <div class="bg-[#0e0e11] border border-[#27272a] rounded-xl w-full max-w-sm p-5 shadow-2xl space-y-4 font-mono">
            <h3 class="text-xs font-semibold text-white uppercase tracking-wider">Create Remote Directory</h3>
            <form phx-submit="create_folder" class="space-y-3">
              <input
                type="text"
                name="name"
                value={@new_folder_name}
                placeholder="Folder name (e.g. backup)"
                class="w-full h-8 px-2.5 bg-[#18181b] border border-[#27272a] rounded text-xs text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-blue-500"
                autofocus
                required
              />
              <div class="flex items-center justify-end gap-2 pt-1">
                <button
                  type="button"
                  phx-click="close_new_folder"
                  class="px-3 py-1 bg-[#202024] text-zinc-400 text-xs rounded hover:text-white"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class="px-3 py-1 bg-blue-600 text-white text-xs rounded hover:bg-blue-500"
                >
                  Create
                </button>
              </div>
            </form>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_directory(socket, path) do
    pid = socket.assigns.sftp_pid

    if is_pid(pid) do
      case SFTP.list_dir(pid, path) do
        {:ok, entries} ->
          assign(socket, current_path: path, entries: entries, loading: false, error: nil)

        {:error, reason} ->
          # Fallback to root if path failed
          if path != "/" do
            load_directory(socket, "/")
          else
            assign(socket, loading: false, error: "Failed to list #{path}: #{inspect(reason)}")
          end
      end
    else
      assign(socket, loading: false)
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
        case Config.load_file(Config.default_config_path()) do
          {:ok, %Config{servers: servers}} ->
            Enum.find(servers, fn s -> s.id == server_id end)

          _ ->
            nil
        end
    end
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end
  defp format_bytes(_), do: "-"
end
