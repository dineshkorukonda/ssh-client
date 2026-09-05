defmodule SSHClient.LocalFS do
  @moduledoc """
  Cross-platform local filesystem explorer for dual-pane SFTP and local file operations.
  Provides structured directory listings, navigation, and file transfers for Windows and Linux.
  """

  @doc "Returns the default starting local directory (User Home or Current Working Dir)"
  def default_path do
    case System.user_home() do
      nil -> File.cwd!()
      home ->
        downloads = Path.join(home, "Downloads")
        if File.dir?(downloads), do: downloads, else: home
    end
  end

  @doc "Lists contents of a local directory, returning sorted structured entries"
  def list_dir(path) when is_binary(path) do
    norm_path = Path.expand(path)

    case File.ls(norm_path) do
      {:ok, filenames} ->
        entries =
          filenames
          |> Enum.reject(&(&1 in [".", ".."]))
          |> Enum.map(fn name ->
            full_path = Path.join(norm_path, name)
            stat = File.stat(full_path)

            case stat do
              {:ok, %File.Stat{type: type, size: size, mtime: mtime, mode: mode}} ->
                %{
                  name: name,
                  path: full_path,
                  type: if(type == :directory, do: :directory, else: :regular),
                  size: size,
                  permissions: format_mode(mode),
                  mtime: mtime
                }

              _ ->
                %{
                  name: name,
                  path: full_path,
                  type: :regular,
                  size: 0,
                  permissions: "0644",
                  mtime: {{1970, 1, 1}, {0, 0, 0}}
                }
            end
          end)
          |> Enum.sort_by(fn entry ->
            {if(entry.type == :directory, do: 0, else: 1), String.downcase(entry.name)}
          end)

        {:ok, entries}

      {:error, reason} ->
        {:error, {:list_dir_failed, reason}}
    end
  end

  @doc "Navigates to parent directory safely"
  def parent_dir(path) when is_binary(path) do
    norm = Path.expand(path)
    parent = Path.dirname(norm)

    if parent == norm do
      norm
    else
      parent
    end
  end

  @doc "Reads a local file"
  def read_file(path) when is_binary(path) do
    File.read(Path.expand(path))
  end

  @doc "Writes data to a local file"
  def write_file(path, data) when is_binary(path) and is_binary(data) do
    norm = Path.expand(path)
    File.write(norm, data)
  end

  @doc "Creates a new local directory"
  def make_dir(path) when is_binary(path) do
    File.mkdir_p(Path.expand(path))
  end

  @doc "Deletes a local file or directory"
  def delete_path(path) when is_binary(path) do
    norm = Path.expand(path)
    if File.dir?(norm) do
      File.rm_rf(norm)
    else
      File.rm(norm)
    end
  end

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

  defp format_mode(mode) when is_integer(mode) do
    octal = Integer.to_string(Bitwise.band(mode, 0o777), 8)
    "0" <> octal
  end
  defp format_mode(_), do: "0644"
end
