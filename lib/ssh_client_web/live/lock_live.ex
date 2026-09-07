defmodule SSHClientWeb.LockLive do
  @moduledoc """
  Vault lock screen and master password initialization interface.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}

  alias SSHClient.Vault

  @impl true
  def mount(_params, _session, socket) do
    status = Vault.status()

    socket =
      socket
      |> assign(:page_title, "Vault Lock — ssh-client")
      |> assign(:vault_status, status)
      |> assign(:show_reset_confirm, false)
      |> assign(:password, "")
      |> assign(:confirm_password, "")
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_reset_confirm", _params, socket) do
    {:noreply, assign(socket, :show_reset_confirm, !socket.assigns.show_reset_confirm)}
  end

  def handle_event("confirm_reset_vault", _params, socket) do
    Vault.destroy_vault()

    socket =
      socket
      |> assign(:vault_status, :uninitialized)
      |> assign(:show_reset_confirm, false)
      |> assign(:error, nil)
      |> assign(:password, "")
      |> assign(:confirm_password, "")

    {:noreply, socket}
  end

  @impl true
  def handle_event("init_vault", %{"password" => p, "confirm_password" => cp}, socket) do
    p = String.trim(p || "")
    cp = String.trim(cp || "")

    cond do
      byte_size(p) < 4 ->
        {:noreply, assign(socket, :error, "Master password must be at least 4 characters.")}

      p != cp ->
        {:noreply, assign(socket, :error, "Passwords do not match.")}

      true ->
        case Vault.init_vault(p) do
          {:ok, :initialized} ->
            {:noreply, push_navigate(socket, to: "/")}

          {:error, reason} ->
            {:noreply, assign(socket, :error, inspect(reason))}
        end
    end
  end

  def handle_event("unlock_vault", %{"password" => p}, socket) do
    p = String.trim(p || "")

    case Vault.unlock(p) do
      {:ok, :unlocked} ->
        {:noreply, push_navigate(socket, to: "/")}

      {:error, :invalid_password} ->
        {:noreply, assign(socket, :error, "Invalid master password. Please try again.")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, inspect(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen w-screen bg-background text-foreground flex items-center justify-center p-4 antialiased relative">
      <!-- Top Theme Switcher -->
      <div class="absolute top-4 right-4">
        <button
          type="button"
          onclick="window.toggleAppTheme()"
          class="h-8 w-8 inline-flex items-center justify-center rounded-md border border-border bg-card text-foreground hover:bg-muted transition-colors"
          title="Toggle Dark / Light Theme"
        >
          <!-- Moon icon for dark mode -->
          <svg class="w-4 h-4 hidden dark:block text-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" />
          </svg>
          <!-- Sun icon for light mode -->
          <svg class="w-4 h-4 block dark:hidden text-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z" />
          </svg>
        </button>
      </div>

      <div class="w-full max-w-sm bg-card border border-border rounded-xl p-8 shadow-xl space-y-6">
        <!-- Brand Header -->
        <div class="flex flex-col items-center text-center space-y-2">
          <div class="flex items-center gap-2.5">
            <img src="/images/icon.png" alt="Logo" class="w-8 h-8 rounded-lg border border-border shadow-xs" />
            <span class="text-foreground font-bold text-base tracking-tight font-sans">ssh-client</span>
            <span class="px-1.5 py-0.5 text-[9px] font-mono font-semibold uppercase tracking-wider rounded bg-primary/10 text-primary border border-primary/20">BETA</span>
          </div>
          <p class="text-xs text-muted-foreground font-mono">Hardware Encrypted Vault</p>
        </div>

        <%= if @error do %>
          <div class="p-3 bg-destructive/10 border border-destructive/30 rounded-lg text-destructive text-xs font-mono">
            <%= @error %>
          </div>
        <% end %>

        <%= if @vault_status == :uninitialized do %>
          <!-- First Time Setup -->
          <form phx-submit="init_vault" class="space-y-4 font-mono text-xs">
            <div class="text-center pb-1">
              <h2 class="text-xs font-semibold text-foreground uppercase tracking-wider">Initialize Master Vault</h2>
              <p class="text-[11px] text-muted-foreground mt-1">Set a master passphrase to encrypt local credentials and private keys.</p>
            </div>

            <div class="space-y-1">
              <label class="block text-[11px] text-muted-foreground uppercase tracking-wider font-sans font-semibold">Master Password</label>
              <input
                type="password"
                name="password"
                placeholder="Enter master password..."
                class="w-full h-9 px-3 bg-background border border-input rounded-md text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
                required
                autofocus
              />
            </div>

            <div class="space-y-1">
              <label class="block text-[11px] text-muted-foreground uppercase tracking-wider font-sans font-semibold">Confirm Password</label>
              <input
                type="password"
                name="confirm_password"
                placeholder="Re-enter master password..."
                class="w-full h-9 px-3 bg-background border border-input rounded-md text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
                required
              />
            </div>

            <button
              type="submit"
              class="w-full h-9 bg-primary text-primary-foreground hover:bg-primary/90 font-medium rounded-md shadow-xs transition-colors"
            >
              Initialize &amp; Unlock Vault
            </button>
          </form>
        <% else %>
          <!-- Unlock Screen -->
          <form phx-submit="unlock_vault" class="space-y-4 font-mono text-xs">
            <div class="text-center pb-1">
              <h2 class="text-xs font-semibold text-foreground uppercase tracking-wider">Vault Locked</h2>
              <p class="text-[11px] text-muted-foreground mt-1">Enter your master passphrase to decrypt stored hosts and credentials.</p>
            </div>

            <div class="space-y-1">
              <label class="block text-[11px] text-muted-foreground uppercase tracking-wider font-sans font-semibold">Master Password</label>
              <input
                type="password"
                name="password"
                placeholder="Enter master password..."
                class="w-full h-9 px-3 bg-background border border-input rounded-md text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
                required
                autofocus
              />
            </div>

            <button
              type="submit"
              class="w-full h-9 bg-primary text-primary-foreground hover:bg-primary/90 font-medium rounded-md shadow-xs transition-colors"
            >
              Unlock Vault
            </button>

            <div class="pt-2 text-center">
              <%= if @show_reset_confirm do %>
                <div class="p-3 bg-destructive/10 border border-destructive/30 rounded-lg text-left space-y-2 mt-2">
                  <p class="text-[11px] text-destructive leading-relaxed">
                    Resetting will clear the master password. Existing unencrypted server entries will be preserved.
                  </p>
                  <div class="flex items-center gap-2 pt-1">
                    <button
                      type="button"
                      phx-click="confirm_reset_vault"
                      class="px-2.5 py-1 bg-destructive text-destructive-foreground hover:bg-destructive/90 rounded text-[10px] font-medium transition-colors"
                    >
                      Confirm Reset
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_reset_confirm"
                      class="px-2.5 py-1 bg-secondary text-secondary-foreground hover:bg-secondary/80 border border-border rounded text-[10px] transition-colors"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              <% else %>
                <button
                  type="button"
                  phx-click="toggle_reset_confirm"
                  class="text-[11px] text-muted-foreground hover:text-foreground underline decoration-dotted transition-colors"
                >
                  Forgot password or reset master vault?
                </button>
              <% end %>
            </div>
          </form>
        <% end %>
      </div>
    </div>
    """
  end
end

