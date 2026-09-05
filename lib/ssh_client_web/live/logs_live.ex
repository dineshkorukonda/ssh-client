defmodule SSHClientWeb.LogsLive do
  @moduledoc """
  Real-time Activity & SSH Connection Log LiveView — displays live streaming
  connection attempts, PTY session lifecycle, polling diagnostics, and error details.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}

  alias SSHClient.ActivityLog
  alias SSHClient.ServerManager
  alias SSHClient.Vault

  @impl true
  def mount(_params, _session, socket) do
    if not Vault.unlocked?() do
      {:ok, push_navigate(socket, to: "/lock")}
    else
      if connected?(socket) do
        ActivityLog.subscribe()
      end

      servers = list_server_ids()
      logs = ActivityLog.list_logs(limit: 200)

      socket =
        socket
        |> assign(:page_title, "Activity Logs — ssh-client")
        |> assign(:servers, servers)
        |> assign(:selected_server, "all")
        |> assign(:selected_level, "all")
        |> assign(:search_query, "")
        |> assign(:logs, logs)
        |> assign(:selected_entry, nil)
        |> assign(:version, "0.0.1")

      {:ok, socket}
    end
  end

  @impl true
  def handle_event("filter_level", %{"level" => level}, socket) do
    {:noreply, assign(socket, :selected_level, level)}
  end

  def handle_event("filter_server", %{"server_id" => server_id}, socket) do
    {:noreply, assign(socket, :selected_server, server_id)}
  end

  def handle_event("search", %{"value" => q}, socket) do
    {:noreply, assign(socket, :search_query, q)}
  end

  def handle_event("clear_logs", _params, socket) do
    ActivityLog.clear()
    {:noreply, assign(socket, logs: [], selected_entry: nil)}
  end

  def handle_event("refresh", _params, socket) do
    logs = ActivityLog.list_logs(limit: 200)
    {:noreply, assign(socket, :logs, logs)}
  end

  def handle_event("view_details", %{"id" => entry_id}, socket) do
    entry = Enum.find(socket.assigns.logs, fn l -> l.id == entry_id end)
    {:noreply, assign(socket, :selected_entry, entry)}
  end

  def handle_event("close_details", _params, socket) do
    {:noreply, assign(socket, :selected_entry, nil)}
  end

  def handle_event("lock_vault", _params, socket) do
    Vault.lock()
    {:noreply, push_navigate(socket, to: "/lock")}
  end

  @impl true
  def handle_info({:new_log_entry, entry}, socket) do
    new_logs = [entry | Enum.take(socket.assigns.logs, 199)]
    {:noreply, assign(socket, :logs, new_logs)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    filtered_logs =
      filter_logs(
        assigns.logs,
        assigns.selected_server,
        assigns.selected_level,
        assigns.search_query
      )

    assigns = assign(assigns, :filtered_logs, filtered_logs)

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
            class="flex items-center gap-2.5 px-3 py-2 rounded-lg text-zinc-500 hover:text-zinc-300 hover:bg-white/5 text-sm font-medium transition-colors"
          >
            Hosts
          </a>
          <a
            href="/logs"
            class="flex items-center gap-2.5 px-3 py-2 rounded-lg bg-blue-600/10 text-blue-400 text-sm font-medium"
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
          <span class="text-[11px] text-zinc-700 font-mono">
            <%= length(@logs) %> events
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
      <div class="flex-1 flex flex-col min-w-0 overflow-hidden">
        <!-- Topbar -->
        <header class="h-14 flex items-center justify-between px-6 border-b border-[#1f1f1f] bg-[#050505] shrink-0">
          <div class="flex items-center gap-3">
            <h1 class="text-sm font-semibold text-white tracking-tight">Activity & Connection Logs</h1>
            <span class="text-[11px] text-zinc-600 font-mono"><%= length(@filtered_logs) %> shown</span>
          </div>

          <div class="flex items-center gap-2">
            <!-- Server filter -->
            <select
              phx-change="filter_server"
              name="server_id"
              class="h-8 px-2.5 bg-[#111] border border-[#1f1f1f] rounded-lg text-xs text-zinc-300 font-mono focus:outline-none"
            >
              <option value="all" selected={@selected_server == "all"}>All Hosts</option>
              <%= for server_id <- @servers do %>
                <option value={server_id} selected={@selected_server == server_id}><%= server_id %></option>
              <% end %>
            </select>

            <!-- Level filter -->
            <div class="flex bg-[#111] border border-[#1f1f1f] rounded-lg p-0.5">
              <%= for {lvl, label} <- [{"all", "All"}, {"info", "Info"}, {"warn", "Warn"}, {"error", "Error"}] do %>
                <button
                  phx-click="filter_level"
                  phx-value-level={lvl}
                  class={["px-2.5 py-1 text-xs rounded-md transition-colors font-medium",
                    if(@selected_level == lvl, do: "bg-blue-600 text-white", else: "text-zinc-500 hover:text-zinc-300")]}
                >
                  <%= label %>
                </button>
              <% end %>
            </div>

            <!-- Search input -->
            <input
              type="text"
              value={@search_query}
              placeholder="Search logs..."
              phx-keyup="search"
              phx-value-value={@search_query}
              class="h-8 px-3 bg-[#111] border border-[#1f1f1f] rounded-lg text-xs text-zinc-300 placeholder-zinc-600 focus:outline-none focus:border-blue-500/60 w-40 font-mono"
            />

            <!-- Clear -->
            <button
              phx-click="clear_logs"
              class="h-8 px-3 bg-[#111] hover:bg-[#1a1a1a] border border-[#1f1f1f] hover:border-red-500/40 text-zinc-400 hover:text-red-400 text-xs rounded-lg transition-colors font-medium"
            >
              Clear
            </button>
          </div>
        </header>

        <!-- Log entries list -->
        <div class="flex-1 overflow-auto p-4">
          <%= if @filtered_logs == [] do %>
            <div class="flex flex-col items-center justify-center h-64 gap-2 text-zinc-600 text-xs font-mono">
              <span>No log events found</span>
              <span class="text-zinc-700">Events from SSH connections, authentication, and worker polling will appear here in real-time.</span>
            </div>
          <% else %>
            <div class="space-y-1 font-mono text-xs">
              <%= for entry <- @filtered_logs do %>
                <div
                  phx-click="view_details"
                  phx-value-id={entry.id}
                  class="flex items-start gap-3 px-3 py-2 rounded-lg bg-[#0a0a0a] border border-[#141414] hover:border-[#27272a] hover:bg-[#111] cursor-pointer transition-colors group"
                >
                  <!-- Timestamp -->
                  <span class="text-zinc-600 shrink-0 text-[11px]">
                    <%= format_timestamp(entry.timestamp) %>
                  </span>

                  <!-- Level Badge -->
                  <span class={["px-1.5 py-0.2 rounded text-[10px] uppercase font-bold tracking-wider shrink-0", level_badge_class(entry.level)]}>
                    <%= entry.level %>
                  </span>

                  <!-- Host Badge -->
                  <%= if entry.server_id do %>
                    <span class="px-2 py-0.2 rounded text-[11px] bg-blue-500/10 text-blue-400 border border-blue-500/20 shrink-0">
                      <%= entry.server_id %>
                    </span>
                  <% end %>

                  <!-- Message -->
                  <span class={["flex-1 break-all", if(entry.level == :error, do: "text-red-300 font-semibold", else: "text-zinc-300")]}>
                    <%= entry.message %>
                  </span>

                  <!-- Details indicator -->
                  <%= if entry.details do %>
                    <span class="text-[10px] text-zinc-600 group-hover:text-blue-400 shrink-0">
                      details &rarr;
                    </span>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>

    <!-- Log Details Modal / Drawer -->
    <%= if @selected_entry do %>
      <div class="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-center justify-center z-50 p-4">
        <div class="bg-[#0a0a0a] border border-[#1f1f1f] rounded-2xl w-full max-w-2xl max-h-[85vh] flex flex-col shadow-2xl overflow-hidden">
          <div class="px-6 py-4 border-b border-[#1f1f1f] flex items-center justify-between shrink-0">
            <div class="flex items-center gap-2">
              <span class={["px-1.5 py-0.5 rounded text-[10px] uppercase font-bold tracking-wider", level_badge_class(@selected_entry.level)]}>
                <%= @selected_entry.level %>
              </span>
              <h3 class="text-sm font-semibold text-white">Log Event Details</h3>
            </div>
            <button phx-click="close_details" class="text-zinc-500 hover:text-zinc-300 text-lg leading-none">&times;</button>
          </div>

          <div class="p-6 overflow-auto space-y-4 font-mono text-xs">
            <div>
              <span class="text-zinc-600 uppercase tracking-wider text-[10px] block mb-1">Timestamp</span>
              <span class="text-zinc-300"><%= DateTime.to_iso8601(@selected_entry.timestamp) %></span>
            </div>

            <%= if @selected_entry.server_id do %>
              <div>
                <span class="text-zinc-600 uppercase tracking-wider text-[10px] block mb-1">Host ID</span>
                <span class="text-blue-400"><%= @selected_entry.server_id %></span>
              </div>
            <% end %>

            <div>
              <span class="text-zinc-600 uppercase tracking-wider text-[10px] block mb-1">Message</span>
              <div class="p-3 bg-[#111] border border-[#1f1f1f] rounded-xl text-zinc-200 break-all">
                <%= @selected_entry.message %>
              </div>
            </div>

            <%= if @selected_entry.details do %>
              <div>
                <span class="text-zinc-600 uppercase tracking-wider text-[10px] block mb-1">Diagnostic Details / Payload</span>
                <pre class="p-3 bg-[#050505] border border-[#1f1f1f] rounded-xl text-zinc-400 overflow-auto max-h-60 text-[11px] whitespace-pre-wrap"><%= @selected_entry.details %></pre>
              </div>
            <% end %>
          </div>

          <div class="px-6 py-3 border-t border-[#1f1f1f] bg-[#080808] flex justify-end shrink-0">
            <button
              phx-click="close_details"
              class="px-4 py-1.5 bg-[#111] hover:bg-[#1a1a1a] border border-[#1f1f1f] text-zinc-300 text-xs font-medium rounded-lg transition-colors"
            >
              Close
            </button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp filter_logs(logs, server_filter, level_filter, query) do
    logs
    |> Enum.filter(fn entry ->
      match_server_filter?(entry.server_id, server_filter) and
        match_level_filter?(entry.level, level_filter) and
        match_query_filter?(entry, query)
    end)
  end

  defp match_server_filter?(_server_id, "all"), do: true
  defp match_server_filter?(server_id, filter), do: server_id == filter

  defp match_level_filter?(_level, "all"), do: true
  defp match_level_filter?(level, filter), do: Atom.to_string(level) == filter

  defp match_query_filter?(_entry, ""), do: true
  defp match_query_filter?(entry, q) do
    query_down = String.downcase(q)
    msg_down = String.downcase(entry.message || "")
    srv_down = String.downcase(entry.server_id || "")
    details_down = String.downcase(entry.details || "")

    String.contains?(msg_down, query_down) or
      String.contains?(srv_down, query_down) or
      String.contains?(details_down, query_down)
  end

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_timestamp(_), do: ""

  defp level_badge_class(:info), do: "bg-blue-500/10 text-blue-400 border border-blue-500/20"
  defp level_badge_class(:warn), do: "bg-amber-500/10 text-amber-400 border border-amber-500/20"
  defp level_badge_class(:error), do: "bg-red-500/10 text-red-400 border border-red-500/20"
  defp level_badge_class(_), do: "bg-zinc-800 text-zinc-500"

  defp list_server_ids do
    try do
      ServerManager.list_servers()
      |> Enum.map(fn s -> to_string(s[:id] || s["id"]) end)
      |> Enum.reject(&(&1 == ""))
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end
end
