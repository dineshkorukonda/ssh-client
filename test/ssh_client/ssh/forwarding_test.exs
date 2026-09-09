defmodule SSHClient.SSH.ForwardingTest do
  use ExUnit.Case, async: false

  alias SSHClient.SSH.Forwarding

  test "registers local and remote rules without connecting" do
    server = %{id: "fwd-host", host: "127.0.0.1", port: 22, user: "test"}

    assert {:ok, local_id} =
             Forwarding.start_local(server, 18_080, "127.0.0.1", 80, auto_connect: false)

    assert {:ok, remote_id} =
             Forwarding.start_remote(server, 18_081, "127.0.0.1", 22, auto_connect: false)

    ids = Enum.map(Forwarding.list(), & &1.id)
    assert local_id in ids
    assert remote_id in ids

    local = Enum.find(Forwarding.list(), &(&1.id == local_id))
    assert local.type == :local
    assert local.status == :idle
    refute Map.has_key?(local, :conn)

    assert :ok = Forwarding.stop(local_id)
    assert :ok = Forwarding.stop(remote_id)
    assert {:error, :not_found} = Forwarding.stop(local_id)
  end
end
