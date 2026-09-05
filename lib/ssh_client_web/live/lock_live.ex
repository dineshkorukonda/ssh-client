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
      |> assign(:password, "")
      |> assign(:confirm_password, "")
      |> assign(:error, nil)

    {:ok, socket}
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
    <div class="min-h-screen w-screen bg-[#050505] flex items-center justify-center p-4">
      <div class="w-full max-w-sm bg-[#0a0a0a] border border-[#1f1f1f] rounded-2xl p-6 shadow-2xl space-y-6">
        <!-- Brand Header -->
        <div class="flex flex-col items-center text-center space-y-2">
          <div class="flex items-center gap-2">
            <img src="/images/icon.png" alt="Logo" class="w-8 h-8 rounded-md invert" />
            <span class="text-white font-bold text-base tracking-tight">ssh-client</span>
            <span class="px-1.5 py-0.5 text-[9px] font-mono font-semibold uppercase tracking-wider rounded bg-red-500/10 text-red-400 border border-red-500/20">BETA</span>
          </div>
          <p class="text-xs text-zinc-500 font-mono">Client-side Encrypted Vault</p>
        </div>

        <%= if @error do %>
          <div class="px-3 py-2 bg-red-500/10 border border-red-500/20 rounded-lg text-red-400 text-xs font-mono">
            <%= @error %>
          </div>
        <% end %>

        <%= if @vault_status == :uninitialized do %>
          <!-- First Time Setup -->
          <form phx-submit="init_vault" class="space-y-4">
            <div class="text-center">
              <h2 class="text-xs font-semibold text-zinc-300 uppercase tracking-wider font-mono">Set Master Password</h2>
              <p class="text-[11px] text-zinc-600 mt-1">This password encrypts your stored SSH keys and server credentials.</p>
            </div>

            <div>
              <label class="block text-[11px] text-zinc-500 font-mono uppercase tracking-wider mb-1.5">Master Password / PIN</label>
              <input
                type="password"
                name="password"
                placeholder="Enter a secure password..."
                class="w-full h-9 px-3 bg-[#111] border border-[#27272a] focus:border-blue-500 rounded-lg text-sm text-zinc-200 placeholder-zinc-700 focus:outline-none font-mono"
                required
                autofocus
              />
            </div>

            <div>
              <label class="block text-[11px] text-zinc-500 font-mono uppercase tracking-wider mb-1.5">Confirm Master Password</label>
              <input
                type="password"
                name="confirm_password"
                placeholder="Re-enter password..."
                class="w-full h-9 px-3 bg-[#111] border border-[#27272a] focus:border-blue-500 rounded-lg text-sm text-zinc-200 placeholder-zinc-700 focus:outline-none font-mono"
                required
              />
            </div>

            <button
              type="submit"
              class="w-full h-9 bg-blue-600 hover:bg-blue-500 text-white text-xs font-mono font-medium rounded-lg transition-colors shadow-sm"
            >
              Initialize & Unlock Vault
            </button>
          </form>
        <% else %>
          <!-- Unlock Screen -->
          <form phx-submit="unlock_vault" class="space-y-4">
            <div class="text-center">
              <h2 class="text-xs font-semibold text-zinc-300 uppercase tracking-wider font-mono">Vault Locked</h2>
              <p class="text-[11px] text-zinc-600 mt-1">Enter your master password to access your servers.</p>
            </div>

            <div>
              <label class="block text-[11px] text-zinc-500 font-mono uppercase tracking-wider mb-1.5">Master Password</label>
              <input
                type="password"
                name="password"
                placeholder="Enter password..."
                class="w-full h-9 px-3 bg-[#111] border border-[#27272a] focus:border-blue-500 rounded-lg text-sm text-zinc-200 placeholder-zinc-700 focus:outline-none font-mono"
                required
                autofocus
              />
            </div>

            <button
              type="submit"
              class="w-full h-9 bg-blue-600 hover:bg-blue-500 text-white text-xs font-mono font-medium rounded-lg transition-colors shadow-sm"
            >
              Unlock Vault
            </button>
          </form>
        <% end %>
      </div>
    </div>
    """
  end
end
