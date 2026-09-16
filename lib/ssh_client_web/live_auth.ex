defmodule SSHClientWeb.LiveAuth do
  @moduledoc """
  Shared LiveView lifecycle hooks for authentication and vault state verification.
  Ensures protected views redirect to the master vault lock page if locked.
  """

  import Phoenix.LiveView

  alias SSHClient.Vault

  @doc """
  Verifies that the vault is unlocked before allowing LiveView mount/render.
  Redirects to `/lock` when the vault is locked or uninitialized.
  """
  def on_mount(:require_unlocked, _params, _session, socket) do
    if Vault.unlocked?() do
      {:cont, socket}
    else
      {:halt, push_navigate(socket, to: "/lock")}
    end
  end
end
