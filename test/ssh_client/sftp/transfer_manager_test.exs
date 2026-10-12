defmodule SSHClient.SFTP.TransferManagerTest do
  use ExUnit.Case, async: false

  alias SSHClient.SFTP.TransferManager

  test "tracks transfer lifecycle states, progress, speed, and cancel" do
    {:ok, transfer_id} = TransferManager.queue_test_transfer("test.txt", 1_000_000)
    assert is_binary(transfer_id)

    transfer = TransferManager.get_transfer(transfer_id)
    assert transfer.status in [:queued, :transferring, :completed]
    assert transfer.filename == "test.txt"

    assert :ok = TransferManager.cancel_transfer(transfer_id)
    assert TransferManager.get_transfer(transfer_id).status == :cancelled
  end

  test "cancelled and retried attempts ignore late updates" do
    {:ok, id} = TransferManager.queue_test_transfer("cancel-race.txt", 100)
    assert {:error, :transfer_not_retryable} = TransferManager.retry_transfer(id)
    assert :ok = TransferManager.cancel_transfer(id)
    send(TransferManager, {:transfer_update, id, 0, %{status: :completed}})
    assert TransferManager.get_transfer(id).status == :cancelled
    assert :ok = TransferManager.retry_transfer(id)
    send(TransferManager, {:transfer_update, id, 0, %{status: :completed}})
    assert TransferManager.get_transfer(id).status == :queued
    assert TransferManager.get_transfer(id).attempt == 1
  end
end
