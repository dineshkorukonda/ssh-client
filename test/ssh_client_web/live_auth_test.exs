defmodule SSHClientWeb.LiveAuthTest do
  use ExUnit.Case, async: false

  alias SSHClientWeb.LiveAuth
  alias SSHClient.Vault

  setup do
    Vault.destroy_vault()
    :ok
  end

  test "on_mount redirects to /lock when vault is locked" do
    {:ok, :initialized} = Vault.init_vault("test-secret-1234")
    :ok = Vault.lock()
    socket = %Phoenix.LiveView.Socket{}

    assert {:halt, halted_socket} =
             LiveAuth.on_mount(:require_unlocked, %{}, %{}, socket)

    assert halted_socket.redirected == {:live, :redirect, %{kind: :push, to: "/lock"}}
  end

  test "on_mount allows access when vault is unlocked" do
    {:ok, :initialized} = Vault.init_vault("test-secret-1234")
    socket = %Phoenix.LiveView.Socket{}

    assert {:cont, continued_socket} =
             LiveAuth.on_mount(:require_unlocked, %{}, %{}, socket)

    assert continued_socket == socket
  end

  test "on_mount allows access when vault is uninitialized" do
    Vault.destroy_vault()
    socket = %Phoenix.LiveView.Socket{}

    assert {:cont, continued_socket} =
             LiveAuth.on_mount(:require_unlocked, %{}, %{}, socket)

    assert continued_socket == socket
  end
end
