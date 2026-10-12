defmodule SSHClient.SFTP.TransferManager do
  @moduledoc """
  Background SFTP transfer queue with progress, cancel, and retry.
  """

  use GenServer

  alias SSHClient.SFTP
  alias SSHClient.SSH

  @name __MODULE__

  defstruct transfers: %{}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def queue_upload(channel_pid, local_path, remote_path, opts \\ []) do
    queue(@name, :upload, channel_pid, local_path, remote_path, opts)
  end

  def queue_download(channel_pid, remote_path, local_path, opts \\ []) do
    queue(@name, :download, channel_pid, remote_path, local_path, opts)
  end

  def queue_session_upload(session_id, local_path, remote_path),
    do: queue(@name, :upload, nil, local_path, remote_path, session_id: session_id)

  def queue_session_download(session_id, remote_path, local_path),
    do: queue(@name, :download, nil, remote_path, local_path, session_id: session_id)

  def queue_test_transfer(filename, total_bytes) do
    GenServer.call(@name, {:queue_test, filename, total_bytes})
  end

  def list_transfers(server \\ @name), do: GenServer.call(server, :list)
  def get_transfer(id), do: GenServer.call(@name, {:get, id})
  def cancel_transfer(id), do: GenServer.call(@name, {:cancel, id})
  def retry_transfer(id), do: GenServer.call(@name, {:retry, id})
  def update_transfer(id, attrs), do: GenServer.call(@name, {:update, id, attrs})

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:update, id, attrs}, _from, state) do
    case Map.get(state.transfers, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      transfer ->
        updated = Map.merge(transfer, attrs)
        broadcast(updated)
        {:reply, {:ok, updated}, put_in(state.transfers[id], updated)}
    end
  end

  @impl true
  def handle_call({:queue, transfer}, _from, state) do
    transfers = Map.put(state.transfers, transfer.id, transfer)
    start_worker(transfer)
    {:reply, {:ok, transfer.id}, %{state | transfers: transfers}}
  end

  def handle_call({:queue_test, filename, total_bytes}, _from, state) do
    transfer = new_transfer(:upload, filename, filename, filename, total_bytes, nil)
    transfers = Map.put(state.transfers, transfer.id, %{transfer | status: :queued})
    {:reply, {:ok, transfer.id}, %{state | transfers: transfers}}
  end

  def handle_call(:list, _from, state) do
    list =
      state.transfers
      |> Map.values()
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    {:reply, list, state}
  end

  def handle_call({:get, id}, _from, state) do
    {:reply, Map.get(state.transfers, id), state}
  end

  def handle_call({:cancel, id}, _from, state) do
    case Map.get(state.transfers, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      transfer ->
        if is_pid(transfer.worker) and Process.alive?(transfer.worker) do
          Process.exit(transfer.worker, :kill)
        end

        updated = %{transfer | status: :cancelled, worker: nil}
        {:reply, :ok, put_in(state.transfers[id], updated)}
    end
  end

  def handle_call({:retry, id}, _from, state) do
    case Map.get(state.transfers, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} when status not in [:failed, :cancelled] ->
        {:reply, {:error, :transfer_not_retryable}, state}

      transfer ->
        retried = %{
          transfer
          | status: :queued,
            error: nil,
            bytes_transferred: 0,
            progress: 0,
            attempt: transfer.attempt + 1
        }

        start_worker(retried)
        {:reply, :ok, put_in(state.transfers[id], retried)}
    end
  end

  @impl true
  def handle_info({:transfer_update, id, attempt, attrs}, state) do
    case Map.get(state.transfers, id) do
      nil ->
        {:noreply, state}

      %{status: status, attempt: current} when status == :cancelled or current != attempt ->
        {:noreply, state}

      transfer ->
        updated = Map.merge(transfer, attrs)
        broadcast(updated)
        {:noreply, put_in(state.transfers[id], updated)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp queue(name, direction, channel_pid, source, dest, opts) do
    filename = Keyword.get(opts, :filename, Path.basename(source))
    total = Keyword.get(opts, :total_bytes, 0)
    caller = Keyword.get(opts, :caller, self())
    host = Keyword.get(opts, :server)
    transfer = new_transfer(direction, filename, source, dest, total, channel_pid)

    transfer = %{
      transfer
      | caller: caller,
        server: host,
        session_id: Keyword.get(opts, :session_id)
    }

    GenServer.call(name, {:queue, transfer})
  end

  defp new_transfer(direction, filename, source, dest, total, channel_pid) do
    %{
      id: "tx-" <> Integer.to_string(System.unique_integer([:positive])),
      direction: direction,
      filename: filename,
      source: source,
      destination: dest,
      status: :queued,
      progress: 0,
      bytes_transferred: 0,
      total_bytes: total,
      speed_bps: 0,
      eta_seconds: 0,
      error: nil,
      channel_pid: channel_pid,
      server: nil,
      worker: nil,
      caller: nil,
      session_id: nil,
      attempt: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp start_worker(%{channel_pid: nil, server: nil, session_id: nil} = _transfer), do: :ok

  defp start_worker(transfer) do
    manager = self()

    {:ok, pid} =
      Task.start(fn ->
        send(
          manager,
          {:transfer_update, transfer.id, transfer.attempt,
           %{status: :transferring, worker: self()}}
        )

        result =
          try do
            {channel, _owned?} = resolve_channel(transfer)

            case channel do
              pid when is_pid(pid) -> run_transfer(transfer, pid, manager)
              _ -> {:error, :not_connected}
            end
          catch
            kind, reason -> {:error, {kind, reason}}
          after
            close_owned(transfer)
          end

        case result do
          :ok ->
            send(
              manager,
              {:transfer_update, transfer.id, transfer.attempt,
               %{status: :completed, progress: 100, worker: nil}}
            )

          {:error, reason} ->
            send(
              manager,
              {:transfer_update, transfer.id, transfer.attempt,
               %{status: :failed, error: inspect(reason), worker: nil}}
            )
        end
      end)

    send(self(), {:transfer_update, transfer.id, transfer.attempt, %{worker: pid}})
  end

  defp run_transfer(%{direction: :upload} = transfer, pid, manager) do
    SFTP.upload_file(pid, transfer.source, transfer.destination, fn meta ->
      send(manager, {:transfer_update, transfer.id, transfer.attempt, progress_attrs(meta)})
    end)
  end

  defp run_transfer(%{direction: :download} = transfer, pid, manager) do
    SFTP.download_file(pid, transfer.source, transfer.destination, fn meta ->
      send(manager, {:transfer_update, transfer.id, transfer.attempt, progress_attrs(meta)})
    end)
  end

  defp resolve_channel(%{channel_pid: pid}) when is_pid(pid), do: {pid, false}

  defp resolve_channel(%{session_id: id}) when is_binary(id) do
    with {:ok, worker} <- SSHClient.SessionManager.get_session(id),
         {:ok, connection} <- SSHClient.SessionWorker.connection(worker),
         {:ok, channel} <- SFTP.start_channel(connection) do
      Process.put(:owned_sftp, {:shared, channel})
      {channel, true}
    else
      _ -> {nil, false}
    end
  end

  defp resolve_channel(%{server: server}) when not is_nil(server) do
    case SSH.connect(server) do
      {:ok, conn} ->
        case SFTP.start_channel(conn) do
          {:ok, pid} ->
            Process.put(:owned_sftp, {conn, pid})
            {pid, true}

          {:error, _} ->
            SSH.close(conn)
            {nil, false}
        end

      _ ->
        {nil, false}
    end
  end

  defp resolve_channel(_), do: {nil, false}

  defp close_owned(_transfer) do
    case Process.get(:owned_sftp) do
      {:shared, pid} ->
        SFTP.stop_channel(pid)

      {conn, pid} ->
        SFTP.stop_channel(pid)
        SSH.close(conn)

      _ ->
        :ok
    end
  end

  defp progress_attrs(meta) do
    %{
      status: :transferring,
      progress: Map.get(meta, :percent, 0),
      bytes_transferred: Map.get(meta, :transferred, 0),
      total_bytes: Map.get(meta, :total, 0),
      speed_bps: Map.get(meta, :speed, 0),
      eta_seconds: Map.get(meta, :eta, 0)
    }
  end

  defp broadcast(transfer) do
    try do
      Phoenix.PubSub.broadcast(
        SSHClient.PubSub,
        "ssh_client:transfers",
        {:transfer_update, transfer}
      )
    rescue
      _ -> :ok
    end

    if is_pid(transfer.caller) do
      send(transfer.caller, {:transfer_update, transfer})
    end
  end
end
