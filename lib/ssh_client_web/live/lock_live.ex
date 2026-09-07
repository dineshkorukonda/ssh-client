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
    <div class="min-h-screen w-screen bg-[#09090b] flex items-center justify-center p-4 antialiased">
      <div class="w-full max-w-sm stark-card bg-[#121215] border border-zinc-800 rounded-lg p-6 shadow-2xl space-y-6">
        <!-- Brand Header -->
        <div class="flex flex-col items-center text-center space-y-2">
          <div class="flex items-center gap-2">
            <img src="/images/icon.png" alt="Logo" class="w-8 h-8 rounded-md border border-zinc-800" />
            <span class="text-white font-bold text-base tracking-tight font-mono">ssh-client</span>
            <span class="px-1.5 py-0.5 text-[9px] font-mono font-semibold uppercase tracking-wider rounded bg-red-500/10 text-red-400 border border-red-500/20">BETA</span>
          </div>
          <p class="text-xs text-zinc-500 font-mono">Hardware Encrypted Vault</p>
        </div>

        <%= if @error do %>
          <div class="px-3 py-2 bg-red-950/50 border border-red-800/50 rounded text-red-300 text-xs font-mono">
            <%= @error %>
          </div>
        <% end %>

        <%= if @vault_status == :uninitialized do %>
          <!-- First Time Setup -->
          <form phx-submit="init_vault" class="space-y-4 font-mono text-xs">
            <div class="text-center">
              <h2 class="text-xs font-semibold text-zinc-300 uppercase tracking-wider">Initialize Master Vault</h2>
              <p class="text-[11px] text-zinc-500 mt-1">This password encrypts your stored SSH keys and server credentials.</p>
            </div>

            <div>
              <label class="block text-[11px] text-zinc-400 uppercase tracking-wider mb-1">Master Password / PIN</label>
              <input
                type="password"
                name="password"
                placeholder="Enter a secure password..."
                class="input input-sm w-full bg-[#18181b] border-zinc-800 focus:border-zinc-500 rounded text-zinc-200"
                required
                autofocus
              />
            </div>

            <div>
              <label class="block text-[11px] text-zinc-400 uppercase tracking-wider mb-1">Confirm Master Password</label>
              <input
                type="password"
                name="confirm_password"
                placeholder="Re-enter password..."
                class="input input-sm w-full bg-[#18181b] border-zinc-800 focus:border-zinc-500 rounded text-zinc-200"
                required
              />
            </div>

            <button
              type="submit"
              class="btn btn-sm w-full bg-white text-zinc-950 hover:bg-zinc-200 border-none font-medium rounded shadow-sm"
            >
              Initialize & Unlock Vault
            </button>
          </form>
        <% else %>
          <!-- Unlock Screen -->
          <form phx-submit="unlock_vault" class="space-y-4 font-mono text-xs">
            <div class="text-center">
              <h2 class="text-xs font-semibold text-zinc-300 uppercase tracking-wider">Vault Locked</h2>
              <p class="text-[11px] text-zinc-500 mt-1">Enter your master password to access your servers.</p>
            </div>

            <div>
              <label class="block text-[11px] text-zinc-400 uppercase tracking-wider mb-1">Master Password</label>
              <input
                type="password"
                name="password"
                placeholder="Enter master password..."
                class="input input-sm w-full bg-[#18181b] border-zinc-800 focus:border-zinc-500 rounded text-zinc-200"
                required
                autofocus
              />
            </div>

            <button
              type="submit"
              class="btn btn-sm w-full bg-white text-zinc-950 hover:bg-zinc-200 border-none font-medium rounded shadow-sm"
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
