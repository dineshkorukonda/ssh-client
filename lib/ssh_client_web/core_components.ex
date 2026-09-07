defmodule SSHClientWeb.CoreComponents do
  @moduledoc """
  Provides core UI components used throughout the application.
  Implements the Shadcn design system with dual-theme (dark & light) support.
  """

  use Phoenix.Component

  @doc "Shadcn Top Navigation Header"
  attr :current_tab, :atom, default: :hosts
  attr :version, :string, default: "0.0.22"
  attr :servers_count, :integer, default: 0
  attr :online_count, :integer, default: 0

  def top_navigation(assigns) do
    ~H"""
    <header class="w-full border-b border-border bg-card/75 backdrop-blur-md px-6 h-14 flex items-center justify-between shrink-0 select-none">
      <!-- Left: Logo & App Brand -->
      <div class="flex items-center gap-3">
        <a href="/" class="flex items-center gap-2.5 group">
          <div class="w-7 h-7 rounded-md bg-primary text-primary-foreground font-mono font-bold text-xs flex items-center justify-center shadow-sm">
            <span>&gt;_</span>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-foreground font-semibold text-sm tracking-tight">ssh-client</span>
            <span class="text-[10px] font-mono text-muted-foreground">v<%= @version %></span>
          </div>
        </a>
        <span class="px-1.5 py-0.5 text-[9px] font-mono font-semibold uppercase tracking-wider rounded bg-destructive/10 text-destructive border border-destructive/20">
          BETA
        </span>
      </div>

      <!-- Center: Segmented Navigation Tabs -->
      <nav class="flex items-center bg-muted/70 p-1 rounded-lg border border-border text-xs font-mono">
        <a
          href="/"
          class={[
            "px-3 py-1.5 rounded-md transition-all font-medium flex items-center gap-1.5",
            if(@current_tab == :hosts,
              do: "bg-background text-foreground shadow-sm font-semibold border border-border/80",
              else: "text-muted-foreground hover:text-foreground hover:bg-background/50"
            )
          ]}
        >
          <span>Hosts</span>
          <%= if @servers_count > 0 do %>
            <span class={[
              "px-1.5 py-0.2 text-[10px] rounded-full font-mono",
              if(@current_tab == :hosts, do: "bg-secondary text-secondary-foreground", else: "bg-muted text-muted-foreground")
            ]}>
              <%= @servers_count %>
            </span>
          <% end %>
        </a>

        <a
          href="/terminal"
          class={[
            "px-3 py-1.5 rounded-md transition-all font-medium flex items-center gap-1.5",
            if(@current_tab == :terminal,
              do: "bg-background text-foreground shadow-sm font-semibold border border-border/80",
              else: "text-muted-foreground hover:text-foreground hover:bg-background/50"
            )
          ]}
        >
          <span>Terminal</span>
        </a>

        <a
          href="/sftp"
          class={[
            "px-3 py-1.5 rounded-md transition-all font-medium flex items-center gap-1.5",
            if(@current_tab == :sftp,
              do: "bg-background text-foreground shadow-sm font-semibold border border-border/80",
              else: "text-muted-foreground hover:text-foreground hover:bg-background/50"
            )
          ]}
        >
          <span>SFTP</span>
        </a>

        <a
          href="/logs"
          class={[
            "px-3 py-1.5 rounded-md transition-all font-medium flex items-center gap-1.5",
            if(@current_tab == :logs,
              do: "bg-background text-foreground shadow-sm font-semibold border border-border/80",
              else: "text-muted-foreground hover:text-foreground hover:bg-background/50"
            )
          ]}
        >
          <span>Logs</span>
        </a>

        <a
          href="/settings"
          class={[
            "px-3 py-1.5 rounded-md transition-all font-medium flex items-center gap-1.5",
            if(@current_tab == :settings,
              do: "bg-background text-foreground shadow-sm font-semibold border border-border/80",
              else: "text-muted-foreground hover:text-foreground hover:bg-background/50"
            )
          ]}
        >
          <span>Settings</span>
        </a>
      </nav>

      <!-- Right: Reachable status, Theme toggle, Vault Lock -->
      <div class="flex items-center gap-3">
        <%= if @servers_count > 0 do %>
          <div class="hidden sm:flex items-center gap-2 px-2.5 py-1 rounded-md bg-muted/60 border border-border text-xs font-mono">
            <span class={"status-dot " <> if(@online_count > 0, do: "online", else: "offline")}></span>
            <span class="text-muted-foreground text-[11px]"><%= @online_count %>/<%= @servers_count %> Online</span>
          </div>
        <% end %>

        <!-- Theme Toggle Button -->
        <button
          type="button"
          onclick="window.toggleAppTheme && window.toggleAppTheme()"
          class="h-8 w-8 flex items-center justify-center rounded-md border border-border bg-background hover:bg-accent text-foreground transition-colors shadow-sm"
          title="Toggle Dark / Light Theme"
        >
          <!-- Sun Icon (shown in dark mode) -->
          <svg class="w-4 h-4 hidden dark:block" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 3v1m0 16v1m9-9h-1M4 9h1m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z" />
          </svg>
          <!-- Moon Icon (shown in light mode) -->
          <svg class="w-4 h-4 block dark:hidden" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" />
          </svg>
        </button>

        <!-- Vault Lock Button -->
        <button
          phx-click="lock_vault"
          class="h-8 px-2.5 flex items-center gap-1.5 rounded-md border border-border bg-background hover:bg-destructive/10 hover:text-destructive hover:border-destructive/30 text-muted-foreground text-xs font-mono transition-colors shadow-sm"
          title="Lock Master Vault"
        >
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" />
          </svg>
          <span class="hidden md:inline">Lock</span>
        </button>
      </div>
    </header>
    """
  end

  @doc "Shadcn Stat Card component"
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :subtext, :string, required: true
  attr :accent, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="shadcn-card p-5 transition-colors hover:border-muted-foreground/30">
      <div class="flex items-center justify-between text-xs font-mono text-muted-foreground uppercase tracking-wider font-medium">
        <span><%= @title %></span>
      </div>
      <div class={["text-2xl font-bold font-mono tracking-tight mt-2 text-foreground", @accent]}>
        <%= @value %>
      </div>
      <div class="text-[11px] text-muted-foreground font-mono mt-1">
        <%= @subtext %>
      </div>
    </div>
    """
  end

  @doc "Status badge component"
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded text-[11px] font-medium font-mono tracking-wide uppercase",
      badge_class(@status)
    ]}>
      <%= @status %>
    </span>
    """
  end

  defp badge_class("polling"), do: "bg-emerald-500/10 text-emerald-500 border border-emerald-500/20"
  defp badge_class("connected"), do: "bg-emerald-500/10 text-emerald-500 border border-emerald-500/20"
  defp badge_class("connecting"), do: "bg-blue-500/10 text-blue-500 border border-blue-500/20"
  defp badge_class("degraded"), do: "bg-amber-500/10 text-amber-500 border border-amber-500/20"
  defp badge_class("reconnecting"), do: "bg-purple-500/10 text-purple-500 border border-purple-500/20"
  defp badge_class(_), do: "bg-muted text-muted-foreground border border-border"

  @doc "Metric bar component"
  attr :label, :string, required: true
  attr :value, :float, default: 0.0

  def metric_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="text-[11px] text-muted-foreground w-8 font-mono"><%= @label %></span>
      <div class="flex-1 h-1.5 bg-muted rounded-full overflow-hidden">
        <div
          class={["h-full rounded-full transition-all duration-500", bar_color(@value)]}
          style={"width: #{min(@value, 100)}%"}
        />
      </div>
      <span class="text-[11px] text-foreground w-10 text-right font-mono font-medium">
        <%= :erlang.float_to_binary(@value + 0.0, decimals: 1) %>%
      </span>
    </div>
    """
  end

  defp bar_color(v) when v >= 90, do: "bg-destructive"
  defp bar_color(v) when v >= 70, do: "bg-warning"
  defp bar_color(_), do: "bg-primary"
end
