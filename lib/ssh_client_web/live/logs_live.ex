defmodule SSHClientWeb.LogsLive do
  @moduledoc """
  Real-time Activity & SSH Connection Log LiveView — displays live streaming
  connection attempts, PTY session lifecycle, polling diagnostics, and error details.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}
  import SSHClientWeb.CoreComponents

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
      all_servers = list_all_servers()
      online_count = count_online_servers()
      logs = ActivityLog.list_logs(limit: 200)

      socket =
        socket
        |> assign(:page_title, "Activity Logs — ssh-client")
        |> assign(:servers, servers)
        |> assign(:servers_count, length(all_servers))
        |> assign(:online_count, online_count)
        |> assign(:selected_server, "all")
        |> assign(:selected_level, "all")
        |> assign(:search_query, "")
        |> assign(:logs, logs)
        |> assign(:selected_entry, nil)
        |> assign(:version, SSHClient.Updater.current_version())

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
    <div class="min-h-screen bg-background text-foreground flex flex-col antialiased">
      <.top_navigation
        current_tab={:logs}
        servers_count={@servers_count}
        online_count={@online_count}
        version={@version}
      />

      <main class="flex-1 container mx-auto max-w-7xl px-4 py-6 flex flex-col space-y-4">
        <!-- Header & Action Toolbar -->
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pb-2 border-b border-border/60">
          <div>
            <h1 class="text-xl font-bold tracking-tight text-foreground font-sans">
              Activity & Telemetry Logs
            </h1>
            <p class="text-xs text-muted-foreground font-mono mt-0.5">
              Real-time audit stream of SSH connections, authentication attempts, SFTP operations, and worker polling.
            </p>
          </div>

          <div class="flex items-center gap-2 flex-wrap">
            <!-- Server filter -->
            <select
              phx-change="filter_server"
              name="server_id"
              class="h-8 px-2.5 bg-background border border-input rounded-md text-xs text-foreground font-mono focus:outline-none focus:ring-1 focus:ring-ring"
            >
              <option value="all" selected={@selected_server == "all"}>All Hosts</option>
              <%= for server_id <- @servers do %>
                <option value={server_id} selected={@selected_server == server_id}>
                  {server_id}
                </option>
              <% end %>
            </select>

            <!-- Level filter tabs -->
            <div class="inline-flex items-center rounded-md bg-muted p-0.5 border border-border">
              <%= for {lvl, label} <- [{"all", "All"}, {"info", "Info"}, {"warn", "Warn"}, {"error", "Error"}] do %>
                <button
                  phx-click="filter_level"
                  phx-value-level={lvl}
                  class={[
                    "px-2.5 py-1 text-xs rounded font-mono font-medium transition-all",
                    if(@selected_level == lvl,
                      do: "bg-background text-foreground shadow-xs",
                      else: "text-muted-foreground hover:text-foreground"
                    )
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>

            <!-- Search input -->
            <div class="relative">
              <svg
                class="absolute left-2.5 top-2.5 w-3.5 h-3.5 text-muted-foreground pointer-events-none"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                />
              </svg>
              <input
                type="text"
                value={@search_query}
                placeholder="Search logs..."
                phx-keyup="search"
                phx-value-value={@search_query}
                class="h-8 pl-8 pr-3 w-44 sm:w-56 bg-background border border-input rounded-md text-xs text-foreground placeholder:text-muted-foreground font-mono focus:outline-none focus:ring-1 focus:ring-ring"
              />
            </div>

            <!-- Clear -->
            <button
              phx-click="clear_logs"
              class="h-8 px-3 rounded-md border border-border bg-card hover:bg-destructive/10 hover:border-destructive/30 hover:text-destructive text-muted-foreground text-xs font-mono font-medium transition-colors"
            >
              Clear
            </button>
          </div>
        </div>

        <!-- Log entries container -->
        <div class="flex-1 bg-card border border-border rounded-xl shadow-xs overflow-hidden flex flex-col min-h-[500px]">
          <div class="px-4 py-2.5 bg-muted/40 border-b border-border flex items-center justify-between font-mono text-xs text-muted-foreground shrink-0">
            <span>Displaying {length(@filtered_logs)} of {length(@logs)} events</span>
            <span class="text-[11px]">Live WebSocket Feed Connected</span>
          </div>

          <div class="flex-1 overflow-auto p-3">
            <%= if @filtered_logs == [] do %>
              <div class="flex flex-col items-center justify-center h-80 gap-2 text-muted-foreground text-xs font-mono">
                <svg
                  class="w-8 h-8 text-muted-foreground/40 mb-1"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="1.5"
                    d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                  />
                </svg>
                <span class="font-medium text-foreground">No log events recorded</span>
                <span class="text-[11px] max-w-sm text-center">Connection attempts, background health checks, and errors will automatically stream here.</span>
              </div>
            <% else %>
              <div class="space-y-1 font-mono text-xs">
                <%= for entry <- @filtered_logs do %>
                  <div
                    phx-click="view_details"
                    phx-value-id={entry.id}
                    class="flex items-center gap-3 px-3 py-2 rounded-lg bg-background hover:bg-muted/60 border border-border/40 hover:border-border cursor-pointer transition-all group"
                  >
                    <!-- Timestamp -->
                    <span class="text-muted-foreground shrink-0 text-[11px] tabular-nums">
                      {format_timestamp(entry.timestamp)}
                    </span>

                    <!-- Level Badge -->
                    <span class={[
                      "px-1.5 py-0.5 rounded text-[10px] uppercase font-bold tracking-wider shrink-0 border",
                      level_badge_class(entry.level)
                    ]}>
                      {entry.level}
                    </span>

                    <!-- Host Badge -->
                    <%= if entry.server_id do %>
                      <span class="px-2 py-0.5 rounded text-[11px] bg-primary/10 text-primary border border-primary/20 shrink-0 font-medium">
                        {entry.server_id}
                      </span>
                    <% end %>

                    <!-- Message -->
                    <span class={[
                      "flex-1 truncate font-mono",
                      if(entry.level == :error,
                        do: "text-destructive font-semibold",
                        else: "text-foreground"
                      )
                    ]}>
                      {entry.message}
                    </span>

                    <!-- Details indicator -->
                    <%= if entry.details do %>
                      <span class="text-[10px] text-muted-foreground group-hover:text-primary shrink-0 transition-colors">
                        Inspect &rarr;
                      </span>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </main>

      <!-- Log Details Modal -->
      <%= if @selected_entry do %>
        <div class="fixed inset-0 bg-black/60 backdrop-blur-xs flex items-center justify-center z-50 p-4">
          <div class="bg-card border border-border text-foreground rounded-xl w-full max-w-2xl max-h-[85vh] flex flex-col shadow-2xl overflow-hidden animate-in fade-in-50 zoom-in-95 duration-150">
            <div class="px-6 py-4 border-b border-border flex items-center justify-between shrink-0">
              <div class="flex items-center gap-2.5">
                <span class={[
                  "px-2 py-0.5 rounded text-[10px] uppercase font-bold tracking-wider border",
                  level_badge_class(@selected_entry.level)
                ]}>
                  {@selected_entry.level}
                </span>
                <h3 class="text-sm font-semibold text-foreground">Log Event Details</h3>
              </div>
              <button
                phx-click="close_details"
                class="p-1 rounded-md text-muted-foreground hover:text-foreground hover:bg-muted transition-colors"
              >
                <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </div>

            <div class="p-6 overflow-auto space-y-4 font-mono text-xs">
              <div class="grid grid-cols-2 gap-4">
                <div class="p-3 bg-muted/40 rounded-lg border border-border/60">
                  <span class="text-muted-foreground uppercase tracking-wider text-[10px] block mb-1">Timestamp</span>
                  <span class="text-foreground font-semibold">{DateTime.to_iso8601(
                    @selected_entry.timestamp
                  )}</span>
                </div>

                <%= if @selected_entry.server_id do %>
                  <div class="p-3 bg-muted/40 rounded-lg border border-border/60">
                    <span class="text-muted-foreground uppercase tracking-wider text-[10px] block mb-1">Host Target</span>
                    <span class="text-primary font-semibold">{@selected_entry.server_id}</span>
                  </div>
                <% end %>
              </div>

              <div>
                <span class="text-muted-foreground uppercase tracking-wider text-[10px] block mb-1">Message</span>
                <div class="p-3 bg-background border border-border rounded-lg text-foreground break-all">
                  {@selected_entry.message}
                </div>
              </div>

              <%= if @selected_entry.details do %>
                <div>
                  <span class="text-muted-foreground uppercase tracking-wider text-[10px] block mb-1">Diagnostic Details / Payload</span>
                  <pre class="p-3 bg-muted border border-border rounded-lg text-foreground overflow-auto max-h-60 text-[11px] whitespace-pre-wrap"><%= @selected_entry.details %></pre>
                </div>
              <% end %>
            </div>

            <div class="px-6 py-3 border-t border-border bg-muted/30 flex justify-end shrink-0">
              <button
                phx-click="close_details"
                class="px-4 py-2 bg-secondary hover:bg-secondary/80 border border-border text-secondary-foreground text-xs font-medium rounded-md transition-colors"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
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

  defp level_badge_class(:info),
    do: "bg-blue-500/10 text-blue-600 dark:text-blue-400 border-blue-500/20"

  defp level_badge_class(:warn),
    do: "bg-amber-500/10 text-amber-600 dark:text-amber-400 border-amber-500/20"

  defp level_badge_class(:error), do: "bg-destructive/10 text-destructive border-destructive/20"
  defp level_badge_class(_), do: "bg-muted text-muted-foreground border-border"

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
