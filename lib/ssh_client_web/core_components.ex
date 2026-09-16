defmodule SSHClientWeb.CoreComponents do
  @moduledoc """
  Provides core UI components used throughout the application.
  Implements the Shadcn design system with dual-theme (dark & light) support.
  Strictly avoids emojis in favor of semantic SVG icons and clean monospace typography.
  """

  use Phoenix.Component

  @doc "Shadcn Top Navigation Header"
  attr :current_tab, :atom, default: :hosts
  attr :version, :string, default: "0.0.38"
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
            <span class="text-[10px] font-mono text-muted-foreground">v{@version}</span>
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
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"
            />
          </svg>
          <span>Hosts</span>
          <%= if @servers_count > 0 do %>
            <span class={[
              "px-1.5 py-0.2 text-[10px] rounded-full font-mono",
              if(@current_tab == :hosts,
                do: "bg-secondary text-secondary-foreground",
                else: "bg-muted text-muted-foreground"
              )
            ]}>
              {@servers_count}
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
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
            />
          </svg>
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
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
            />
          </svg>
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
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
            />
          </svg>
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
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
            />
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
            />
          </svg>
          <span>Settings</span>
        </a>
      </nav>

      <!-- Right: Command palette shortcut, Reachable status, Theme toggle, Vault Lock -->
      <div class="flex items-center gap-2.5">
        <!-- Command Palette Trigger Button / Shortcut hint -->
        <button
          type="button"
          phx-click="toggle_command_palette"
          class="hidden lg:flex items-center gap-2 px-2.5 py-1 rounded-md bg-muted/50 hover:bg-muted text-muted-foreground hover:text-foreground border border-border text-xs font-mono transition-colors shadow-sm"
          title="Open Command Palette (Ctrl+K or Cmd+K)"
        >
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
            />
          </svg>
          <span>Search</span>
          <kbd class="px-1.5 py-0.5 text-[10px] bg-background border border-border rounded text-muted-foreground">Ctrl+K</kbd>
        </button>

        <%= if @servers_count > 0 do %>
          <div class="hidden sm:flex items-center gap-2 px-2.5 py-1 rounded-md bg-muted/60 border border-border text-xs font-mono">
            <span class={"status-dot " <> if(@online_count > 0, do: "online", else: "offline")}></span>
            <span class="text-muted-foreground text-[11px]">{@online_count}/{@servers_count} Online</span>
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
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 3v1m0 16v1m9-9h-1M4 9h1m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z"
            />
          </svg>
          <!-- Moon Icon (shown in light mode) -->
          <svg class="w-4 h-4 block dark:hidden" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z"
            />
          </svg>
        </button>

        <!-- Vault Lock Button -->
        <button
          phx-click="lock_vault"
          class="h-8 px-2.5 flex items-center gap-1.5 rounded-md border border-border bg-background hover:bg-destructive/10 hover:text-destructive hover:border-destructive/30 text-muted-foreground text-xs font-mono transition-colors shadow-sm"
          title="Lock Master Vault"
        >
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
            />
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
        <span>{@title}</span>
      </div>
      <div class={["text-2xl font-bold font-mono tracking-tight mt-2 text-foreground", @accent]}>
        {@value}
      </div>
      <div class="text-[11px] text-muted-foreground font-mono mt-1">
        {@subtext}
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
      {@status}
    </span>
    """
  end

  defp badge_class("polling"),
    do: "bg-emerald-500/10 text-emerald-500 border border-emerald-500/20"

  defp badge_class("connected"),
    do: "bg-emerald-500/10 text-emerald-500 border border-emerald-500/20"

  defp badge_class("connecting"), do: "bg-blue-500/10 text-blue-500 border border-blue-500/20"
  defp badge_class("degraded"), do: "bg-amber-500/10 text-amber-500 border border-amber-500/20"

  defp badge_class("reconnecting"),
    do: "bg-purple-500/10 text-purple-500 border border-purple-500/20"

  defp badge_class(_), do: "bg-muted text-muted-foreground border border-border"

  @doc "Metric bar component"
  attr :label, :string, required: true
  attr :value, :float, default: 0.0

  def metric_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="text-[11px] text-muted-foreground w-8 font-mono">{@label}</span>
      <div class="flex-1 h-1.5 bg-muted rounded-full overflow-hidden">
        <div
          class={["h-full rounded-full transition-all duration-500", bar_color(@value)]}
          style={"width: #{min(@value, 100)}%"}
        />
      </div>
      <span class="text-[11px] text-foreground w-10 text-right font-mono font-medium">
        {:erlang.float_to_binary(@value + 0.0, decimals: 1)}%
      </span>
    </div>
    """
  end

  defp bar_color(v) when v >= 90, do: "bg-destructive"
  defp bar_color(v) when v >= 70, do: "bg-warning"
  defp bar_color(_), do: "bg-primary"

  @doc "Standard Modal overlay component"
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, :string, default: nil
  attr :title, :string, default: nil
  attr :max_width, :string, default: "max-w-lg"
  slot :inner_block, required: true
  slot :actions

  def modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-background/80 backdrop-blur-sm transition-opacity"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div
        class="fixed inset-0"
        phx-click={@on_cancel}
      />
      <div class={[
        "relative w-full bg-card border border-border rounded-lg shadow-xl overflow-hidden z-10 animate-in fade-in zoom-in-95 duration-150",
        @max_width
      ]}>
        <%= if @title || @on_cancel do %>
          <div class="flex items-center justify-between px-5 py-4 border-b border-border bg-muted/40">
            <h3 class="text-sm font-semibold font-mono text-foreground tracking-tight">
              {@title}
            </h3>
            <%= if @on_cancel do %>
              <button
                type="button"
                phx-click={@on_cancel}
                class="p-1 rounded-md text-muted-foreground hover:text-foreground hover:bg-muted transition-colors"
                aria-label="Close"
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
            <% end %>
          </div>
        <% end %>
        <div class="p-5">
          {render_slot(@inner_block)}
        </div>
        <%= if @actions != [] do %>
          <div class="flex items-center justify-end gap-2 px-5 py-3 border-t border-border bg-muted/20">
            {render_slot(@actions)}
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc "Empty state placeholder component"
  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center p-12 text-center rounded-lg border border-dashed border-border bg-card/50">
      <div class="w-10 h-10 rounded-full bg-muted flex items-center justify-center text-muted-foreground mb-3 font-mono text-sm">
        <span>&gt;_</span>
      </div>
      <h3 class="text-sm font-semibold font-mono text-foreground">
        {@title}
      </h3>
      <%= if @description do %>
        <p class="text-xs text-muted-foreground font-mono mt-1 max-w-sm">
          {@description}
        </p>
      <% end %>
      <%= if @action != [] do %>
        <div class="mt-4">
          {render_slot(@action)}
        </div>
      <% end %>
    </div>
    """
  end

  @doc "Breadcrumb navigation bar component"
  attr :items, :list, required: true

  def breadcrumb(assigns) do
    ~H"""
    <nav
      class="flex items-center gap-1.5 text-xs font-mono text-muted-foreground"
      aria-label="Breadcrumb"
    >
      <%= for {item, idx} <- Enum.with_index(@items) do %>
        <%= if idx > 0 do %>
          <span class="text-border">/</span>
        <% end %>
        <%= if Map.get(item, :click) do %>
          <button
            type="button"
            phx-click={item.click}
            phx-value-path={Map.get(item, :path)}
            class="hover:text-foreground transition-colors truncate max-w-xs"
          >
            {item.label}
          </button>
        <% else %>
          <span class="text-foreground font-medium truncate max-w-xs">{item.label}</span>
        <% end %>
      <% end %>
    </nav>
    """
  end
end
