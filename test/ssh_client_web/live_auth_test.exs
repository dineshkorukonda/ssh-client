defmodule SSHClientWeb.LiveAuthTest do
  use ExUnit.Case, async: false

  alias SSHClientWeb.LiveAuth
  alias SSHClient.Vault

  setup do
    Vault.destroy_vault()
    :ok
  end

  test "on_mount always allows access without requiring password" do
    socket = %Phoenix.LiveView.Socket{}

    assert {:cont, continued_socket} =
             LiveAuth.on_mount(:require_unlocked, %{}, %{}, socket)

    assert continued_socket == socket
  end

  test "on_mount allows access regardless of vault state" do
    {:ok, :initialized} = Vault.init_vault("test-secret-1234")
    :ok = Vault.lock()
    socket = %Phoenix.LiveView.Socket{}

    assert {:cont, continued_socket} =
             LiveAuth.on_mount(:require_unlocked, %{}, %{}, socket)

    assert continued_socket == socket
  end
end
