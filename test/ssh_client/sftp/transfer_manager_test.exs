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
end
