defmodule SSHClient.SFTP do
  @moduledoc """
  Erlang :ssh_sftp client wrapper for remote file operations over an active SSH connection.
  Provides directory navigation, chunked streaming uploads/downloads, permission modification,
  and path operations.
  """

  import Bitwise

  alias SSHClient.SSH.Connection

  @doc "Starts an SFTP channel process on an active SSH connection"
  def start_channel(%Connection{conn_ref: conn_ref}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    case :ssh_sftp.start_channel(conn_ref, timeout: timeout) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:sftp_channel_failed, reason}}
    end
  end

  @doc "Closes an active SFTP channel"
  def stop_channel(channel_pid) when is_pid(channel_pid) do
    try do
      :ssh_sftp.stop_channel(channel_pid)
    catch
      _, _ -> :ok
    end
  end

  def stop_channel(_), do: :ok

  @doc "Lists contents of a remote directory, returning structured file entries"
  def list_dir(channel_pid, path) when is_pid(channel_pid) and is_binary(path) do
    path_cl = String.to_charlist(normalize_path(path))

    case :ssh_sftp.list_dir(channel_pid, path_cl) do
      {:ok, filenames} ->
        entries =
          filenames
          |> Enum.map(&List.to_string/1)
          |> Enum.reject(&(&1 in [".", ".."]))
          |> Enum.map(fn filename ->
            full_path = Path.join(path, filename)
            info = get_file_info(channel_pid, full_path)

            %{
              name: filename,
              path: full_path,
              type: info.type,
              size: info.size,
              permissions: format_permissions(info.permissions),
              raw_permissions: info.permissions,
              mtime: info.mtime
            }
          end)
          |> Enum.sort_by(fn entry ->
            # Folders first, then alphabetically
            {if(entry.type == :directory, do: 0, else: 1), String.downcase(entry.name)}
          end)

        {:ok, entries}

      {:error, reason} ->
        {:error, {:list_dir_failed, reason}}
    end
  end

  def list_dir(_, _), do: {:error, :not_connected}

  @doc "Reads contents of a remote text or binary file"
  def read_file(channel_pid, path) when is_pid(channel_pid) and is_binary(path) do
    path_cl = String.to_charlist(normalize_path(path))

    case :ssh_sftp.read_file(channel_pid, path_cl) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:read_file_failed, reason}}
    end
  end

  def read_file(_, _), do: {:error, :not_connected}

  @doc "Writes binary data to a remote file"
  def write_file(channel_pid, path, data)
      when is_pid(channel_pid) and is_binary(path) and is_binary(data) do
    path_cl = String.to_charlist(normalize_path(path))

    case :ssh_sftp.write_file(channel_pid, path_cl, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_file_failed, reason}}
    end
  end

  def write_file(_, _, _), do: {:error, :not_connected}

  @chunk_size 65_536

  @doc "Uploads a local file to remote destination path using chunked streaming with optional progress callback"
  def upload_file(channel_pid, local_path, remote_path, on_progress \\ nil)

  def upload_file(channel_pid, local_path, remote_path, on_progress)
      when is_pid(channel_pid) and is_binary(local_path) and is_binary(remote_path) do
    norm_local = Path.expand(local_path)

    case File.stat(norm_local) do
      {:ok, %File.Stat{size: total_size}} ->
        remote_cl = String.to_charlist(normalize_path(remote_path))

        case :ssh_sftp.open(channel_pid, remote_cl, [:write, :creat, :trunc, :binary]) do
          {:ok, handle} ->
            case File.open(norm_local, [:read, :binary]) do
              {:ok, file_io} ->
                start_time = System.monotonic_time(:millisecond)

                if is_function(on_progress, 1) do
                  on_progress.(%{transferred: 0, total: total_size, percent: 0, speed: 0, eta: 0})
                end

                res =
                  stream_upload_loop(
                    channel_pid,
                    handle,
                    file_io,
                    0,
                    total_size,
                    start_time,
                    on_progress
                  )

                File.close(file_io)
                :ssh_sftp.close(channel_pid, handle)
                res

              {:error, reason} ->
                :ssh_sftp.close(channel_pid, handle)
                {:error, {:local_read_failed, reason}}
            end

          {:error, _reason} ->
            # Fallback to buffer write
            fallback_upload(channel_pid, norm_local, remote_path, on_progress)
        end

      {:error, reason} ->
        {:error, {:local_read_failed, reason}}
    end
  end

  def upload_file(_, _, _, _), do: {:error, :not_connected}

  defp fallback_upload(channel_pid, norm_local, remote_path, on_progress) do
    case File.read(norm_local) do
      {:ok, binary_data} ->
        total_size = byte_size(binary_data)

        if is_function(on_progress, 1),
          do: on_progress.(%{transferred: 0, total: total_size, percent: 0, speed: 0, eta: 0})

        res = write_file(channel_pid, remote_path, binary_data)

        if res == :ok and is_function(on_progress, 1) do
          on_progress.(%{
            transferred: total_size,
            total: total_size,
            percent: 100,
            speed: 0,
            eta: 0
          })
        end

        res

      {:error, reason} ->
        {:error, {:local_read_failed, reason}}
    end
  end

  defp stream_upload_loop(
         channel_pid,
         handle,
         file_io,
         transferred,
         total_size,
         start_time,
         on_progress
       ) do
    case IO.binread(file_io, @chunk_size) do
      data when is_binary(data) and byte_size(data) > 0 ->
        case :ssh_sftp.write(channel_pid, handle, data) do
          :ok ->
            new_transferred = transferred + byte_size(data)
            now = System.monotonic_time(:millisecond)
            elapsed_ms = max(now - start_time, 1)
            speed = round(new_transferred / elapsed_ms * 1000)
            remaining_bytes = max(total_size - new_transferred, 0)
            eta = if speed > 0, do: round(remaining_bytes / speed), else: 0

            percent =
              if total_size > 0, do: min(round(new_transferred / total_size * 100), 99), else: 50

            if is_function(on_progress, 1) do
              on_progress.(%{
                transferred: new_transferred,
                total: total_size,
                percent: percent,
                speed: speed,
                eta: eta
              })
            end

            stream_upload_loop(
              channel_pid,
              handle,
              file_io,
              new_transferred,
              total_size,
              start_time,
              on_progress
            )

          {:error, reason} ->
            {:error, {:write_file_failed, reason}}
        end

      :eof ->
        if is_function(on_progress, 1) do
          on_progress.(%{
            transferred: total_size,
            total: total_size,
            percent: 100,
            speed: 0,
            eta: 0
          })
        end

        :ok

      {:error, reason} ->
        {:error, {:local_read_failed, reason}}
    end
  end

  @doc "Downloads a remote file to a local destination path using chunked streaming with optional progress callback"
  def download_file(channel_pid, remote_path, local_path, on_progress \\ nil)

  def download_file(channel_pid, remote_path, local_path, on_progress)
      when is_pid(channel_pid) and is_binary(remote_path) and is_binary(local_path) do
    remote_cl = String.to_charlist(normalize_path(remote_path))
    info = get_file_info(channel_pid, remote_path)
    total_size = info.size
    norm_local = Path.expand(local_path)

    case :ssh_sftp.open(channel_pid, remote_cl, [:read, :binary]) do
      {:ok, handle} ->
        case File.open(norm_local, [:write, :binary]) do
          {:ok, file_io} ->
            start_time = System.monotonic_time(:millisecond)

            if is_function(on_progress, 1) do
              on_progress.(%{transferred: 0, total: total_size, percent: 0, speed: 0, eta: 0})
            end

            res =
              stream_download_loop(
                channel_pid,
                handle,
                file_io,
                0,
                total_size,
                start_time,
                on_progress
              )

            File.close(file_io)
            :ssh_sftp.close(channel_pid, handle)
            res

          {:error, reason} ->
            :ssh_sftp.close(channel_pid, handle)
            {:error, {:local_write_failed, reason}}
        end

      {:error, _reason} ->
        fallback_download(channel_pid, remote_path, norm_local, on_progress)
    end
  end

  def download_file(_, _, _, _), do: {:error, :not_connected}

  defp fallback_download(channel_pid, remote_path, norm_local, on_progress) do
    case read_file(channel_pid, remote_path) do
      {:ok, binary_data} ->
        total_size = byte_size(binary_data)

        if is_function(on_progress, 1),
          do: on_progress.(%{transferred: 0, total: total_size, percent: 0, speed: 0, eta: 0})

        case File.write(norm_local, binary_data) do
          :ok ->
            if is_function(on_progress, 1) do
              on_progress.(%{
                transferred: total_size,
                total: total_size,
                percent: 100,
                speed: 0,
                eta: 0
              })
            end

            :ok

          {:error, reason} ->
            {:error, {:local_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:remote_read_failed, reason}}
    end
  end

  defp stream_download_loop(
         channel_pid,
         handle,
         file_io,
         transferred,
         total_size,
         start_time,
         on_progress
       ) do
    case :ssh_sftp.read(channel_pid, handle, @chunk_size) do
      {:ok, data} when is_binary(data) and byte_size(data) > 0 ->
        try do
          :ok = IO.binwrite(file_io, data)
          new_transferred = transferred + byte_size(data)
          now = System.monotonic_time(:millisecond)
          elapsed_ms = max(now - start_time, 1)
          speed = round(new_transferred / elapsed_ms * 1000)
          remaining_bytes = max(total_size - new_transferred, 0)
          eta = if speed > 0, do: round(remaining_bytes / speed), else: 0

          percent =
            if total_size > 0, do: min(round(new_transferred / total_size * 100), 99), else: 50

          if is_function(on_progress, 1) do
            on_progress.(%{
              transferred: new_transferred,
              total: total_size,
              percent: percent,
              speed: speed,
              eta: eta
            })
          end

          stream_download_loop(
            channel_pid,
            handle,
            file_io,
            new_transferred,
            total_size,
            start_time,
            on_progress
          )
        rescue
          e -> {:error, {:local_write_failed, Exception.message(e)}}
        end

      :eof ->
        if is_function(on_progress, 1) do
          on_progress.(%{
            transferred: total_size,
            total: total_size,
            percent: 100,
            speed: 0,
            eta: 0
          })
        end

        :ok

      {:error, reason} ->
        {:error, {:remote_read_failed, reason}}
    end
  end

  @doc "Deletes a remote file"
  def delete_file(channel_pid, path) when is_pid(channel_pid) and is_binary(path) do
    path_cl = String.to_charlist(normalize_path(path))

    case :ssh_sftp.delete(channel_pid, path_cl) do
      :ok -> :ok
      {:error, reason} -> {:error, {:delete_failed, reason}}
    end
  end

  def delete_file(_, _), do: {:error, :not_connected}

  @doc "Deletes a remote directory"
  def delete_dir(channel_pid, path) when is_pid(channel_pid) and is_binary(path) do
    path_cl = String.to_charlist(normalize_path(path))

    case :ssh_sftp.del_dir(channel_pid, path_cl) do
      :ok -> :ok
      {:error, reason} -> {:error, {:del_dir_failed, reason}}
    end
  end

  def delete_dir(_, _), do: {:error, :not_connected}

  @doc "Creates a new remote directory"
  def make_dir(channel_pid, path) when is_pid(channel_pid) and is_binary(path) do
    path_cl = String.to_charlist(normalize_path(path))

    case :ssh_sftp.make_dir(channel_pid, path_cl) do
      :ok -> :ok
      {:error, reason} -> {:error, {:make_dir_failed, reason}}
    end
  end

  def make_dir(_, _), do: {:error, :not_connected}

  @doc "Renames a remote file or folder"
  def rename(channel_pid, old_path, new_path)
      when is_pid(channel_pid) and is_binary(old_path) and is_binary(new_path) do
    old_cl = String.to_charlist(normalize_path(old_path))
    new_cl = String.to_charlist(normalize_path(new_path))

    case :ssh_sftp.rename(channel_pid, old_cl, new_cl) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename_failed, reason}}
    end
  end

  def rename(_, _, _), do: {:error, :not_connected}

  @doc "Formats bytes into human readable format"
  def format_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_size(_), do: "0 B"

  # Helpers

  defp get_file_info(channel_pid, full_path) do
    path_cl = String.to_charlist(normalize_path(full_path))

    case :ssh_sftp.read_file_info(channel_pid, path_cl) do
      {:ok, info_record} ->
        # :file_info record fields: {file_info, size, type, access, atime, mtime, ctime, mode, ...}
        size = elem(info_record, 1) || 0
        type = elem(info_record, 2) || :regular
        mode = elem(info_record, 7) || 0o644
        mtime = elem(info_record, 5) || {{1970, 1, 1}, {0, 0, 0}}

        %{size: size, type: type, permissions: mode, mtime: mtime}

      _ ->
        %{size: 0, type: :regular, permissions: 0o644, mtime: {{1970, 1, 1}, {0, 0, 0}}}
    end
  end

  def normalize_path(path) when is_binary(path) do
    path = String.trim(path)
    if path == "" or !String.starts_with?(path, "/"), do: "/" <> path, else: path
  end

  def normalize_path(_), do: "/"

  def format_permissions(mode) when is_integer(mode) do
    octal = Integer.to_string(band(mode, 0o777), 8)
    "0" <> octal
  end

  def format_permissions(_), do: "0644"
end
