defmodule SSHClient.Updater do
  @moduledoc """
  Robust application updater for ssh-client.
  Provides update checking from GitHub Releases, multi-platform asset detection,
  in-app background downloading with progress reporting, and automatic
  installer execution on Windows and Linux.
  """

  require Logger

  @current_version "0.0.4"
  @repo_owner "dineshkorukonda"
  @repo_name "ssh-client"
  @api_url "https://api.github.com/repos/#{@repo_owner}/#{@repo_name}/releases/latest"

  @doc """
  Returns the current running version of the application.
  """
  def current_version, do: @current_version

  @doc """
  Checks GitHub Releases for the latest version.
  Tries native OTP :httpc first, then gracefully falls back to curl or powershell.
  Returns `{:ok, info}` or `{:error, reason}`.
  """
  def check_update(opts \\ []) do
    api_url = Keyword.get(opts, :api_url, @api_url)
    timeout = Keyword.get(opts, :timeout, 8000)

    case fetch_json(api_url, timeout) do
      {:ok, data} when is_map(data) ->
        latest_tag = Map.get(data, "tag_name", "v#{@current_version}")
        latest_version = String.trim_leading(latest_tag, "v")
        html_url = Map.get(data, "html_url", "https://github.com/#{@repo_owner}/#{@repo_name}/releases")
        published_at = Map.get(data, "published_at")
        body_notes = Map.get(data, "body", "")

        assets =
          data
          |> Map.get("assets", [])
          |> Enum.map(fn asset ->
            name = Map.get(asset, "name", "")
            %{
              name: name,
              browser_download_url: Map.get(asset, "browser_download_url", ""),
              size: Map.get(asset, "size", 0),
              type: classify_asset(name)
            }
          end)

        update_available? = version_greater?(latest_version, @current_version)
        platform = detect_os()
        platform_asset = select_platform_asset(assets, platform)

        {:ok,
         %{
           current_version: @current_version,
           latest_version: latest_version,
           tag_name: latest_tag,
           update_available?: update_available?,
           release_url: html_url,
           notes: body_notes,
           published_at: published_at,
           assets: assets,
           platform: platform,
           platform_asset: platform_asset
         }}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Downloads a release asset binary to a local temporary path.
  Optionally streams progress to `caller_pid` in the form:
  `{:update_download_progress, percent, bytes_downloaded, total_bytes}`
  """
  def download_update(asset_url, target_filename \\ nil, opts \\ []) do
    caller_pid = Keyword.get(opts, :caller_pid, self())
    filename = target_filename || Path.basename(asset_url)
    tmp_dir = System.tmp_dir!()
    target_path = Path.join(tmp_dir, filename)

    case download_file(asset_url, target_path, caller_pid) do
      {:ok, path} ->
        {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Installs or executes the downloaded update package.
  On Windows: launches .exe installer or opens archive.
  On Linux: unpacks tarball or launches new binary.
  """
  def install_update(file_path) do
    if not File.exists?(file_path) do
      {:error, "Downloaded update file not found at: #{file_path}"}
    else
      ext = file_path |> Path.extname() |> String.downcase()

      case {detect_os(), ext} do
        {:windows, ".exe"} ->
          case System.cmd("cmd.exe", ["/c", "start", "", file_path]) do
            {_, 0} ->
              {:ok, :installer_launched, "Windows Setup installer launched. Follow the on-screen installer to complete update."}

            {err, code} ->
              {:error, "Failed to launch installer (code #{code}): #{err}"}
          end

        {:windows, ".zip"} ->
          case System.cmd("explorer.exe", ["/select,", file_path]) do
            _ ->
              {:ok, :archive_opened, "Update archive opened in File Explorer. Extract to update."}
          end

        {:linux, ".gz"} ->
          dest_dir = Path.expand("~/.local/ssh-client")
          File.mkdir_p!(dest_dir)
          case System.cmd("tar", ["-xzf", file_path, "-C", dest_dir]) do
            {_, 0} ->
              {:ok, :tarball_extracted, "Update extracted to #{dest_dir}. Restart the service to apply changes."}

            {err, _} ->
              {:ok, :manual_install, "Downloaded to #{file_path}. Error auto-extracting: #{err}."}
          end

        {_, _} ->
          {:ok, :download_ready, "Update file ready at: #{file_path}"}
      end
    end
  rescue
    e -> {:error, "Installation error: #{Exception.message(e)}"}
  end

  # ===================================================================
  # HTTP & Fetching Internals
  # ===================================================================

  defp fetch_json(url, timeout) do
    case try_httpc_get(url, timeout) do
      {:ok, body} ->
        decode_json(body)

      {:error, _reason} ->
        case try_curl_get(url, timeout) do
          {:ok, body} ->
            decode_json(body)

          {:error, _} ->
            if detect_os() == :windows do
              case try_powershell_get(url) do
                {:ok, body} -> decode_json(body)
                {:error, ps_err} -> {:error, "Update check failed: #{ps_err}"}
              end
            else
              {:error, "Unable to reach update servers. Please check your internet connection."}
            end
        end
    end
  end

  defp try_httpc_get(url, timeout) do
    try do
      if Code.ensure_loaded?(:inets) and function_exported?(:inets, :start, 0) do
        :inets.start()
        :ssl.start()

        headers = [
          {~c"User-Agent", ~c"ssh-client/#{@current_version}"},
          {~c"Accept", ~c"application/vnd.github.v3+json"}
        ]

        http_opts = [
          timeout: timeout,
          connect_timeout: timeout,
          ssl: [verify: :verify_none]
        ]

        case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts, body_format: :binary) do
          {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
          {:ok, {{_, 404, _}, _, _}} -> {:error, :not_found}
          {:ok, {{_, status, _}, _, _}} -> {:error, "HTTP status #{status}"}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :inets_not_available}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      _, reason -> {:error, reason}
    end
  end

  defp try_curl_get(url, _timeout) do
    try do
      case System.cmd("curl", ["-s", "-L", "-H", "User-Agent: ssh-client/#{@current_version}", "-H", "Accept: application/vnd.github.v3+json", url]) do
        {output, 0} when byte_size(output) > 0 ->
          {:ok, output}

        _ ->
          {:error, :curl_failed}
      end
    rescue
      _ -> {:error, :curl_not_found}
    end
  end

  defp try_powershell_get(url) do
    try do
      script = "$ProgressPreference = 'SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (Invoke-WebRequest -Uri '#{url}' -Headers @{'User-Agent'='ssh-client/#{@current_version}'; 'Accept'='application/vnd.github.v3+json'} -UseBasicParsing).Content"
      case System.cmd("powershell", ["-NoProfile", "-Command", script]) do
        {output, 0} when byte_size(output) > 0 ->
          {:ok, output}

        {err, _} ->
          {:error, err}
      end
    rescue
      _ -> {:error, :powershell_not_found}
    end
  end

  defp download_file(url, target_path, caller_pid) do
    cond do
      System.find_executable("curl") != nil ->
        download_with_curl(url, target_path, caller_pid)

      detect_os() == :windows and System.find_executable("powershell") != nil ->
        download_with_powershell(url, target_path, caller_pid)

      true ->
        download_with_httpc(url, target_path, caller_pid)
    end
  end

  defp download_with_curl(url, target_path, caller_pid) do
    if is_pid(caller_pid), do: send(caller_pid, {:update_download_progress, 15, 0, 0})
    case System.cmd("curl", ["-s", "-L", "-o", target_path, url]) do
      {_, 0} ->
        if File.exists?(target_path) and File.stat!(target_path).size > 0 do
          size = File.stat!(target_path).size
          if is_pid(caller_pid), do: send(caller_pid, {:update_download_progress, 100, size, size})
          {:ok, target_path}
        else
          {:error, "Downloaded file is empty"}
        end

      {err, _} ->
        {:error, "curl download failed: #{err}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp download_with_powershell(url, target_path, caller_pid) do
    if is_pid(caller_pid), do: send(caller_pid, {:update_download_progress, 20, 0, 0})
    script = "$ProgressPreference = 'SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '#{url}' -OutFile '#{target_path}' -UseBasicParsing"
    case System.cmd("powershell", ["-NoProfile", "-Command", script]) do
      {_, 0} ->
        if File.exists?(target_path) and File.stat!(target_path).size > 0 do
          size = File.stat!(target_path).size
          if is_pid(caller_pid), do: send(caller_pid, {:update_download_progress, 100, size, size})
          {:ok, target_path}
        else
          {:error, "Downloaded file is empty"}
        end

      {err, _} ->
        {:error, "powershell download failed: #{err}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp download_with_httpc(url, target_path, caller_pid) do
    if is_pid(caller_pid), do: send(caller_pid, {:update_download_progress, 10, 0, 0})
    try do
      if Code.ensure_loaded?(:inets) and function_exported?(:inets, :start, 0) do
        :inets.start()
        :ssl.start()
        headers = [{~c"User-Agent", ~c"ssh-client/#{@current_version}"}]
        http_opts = [timeout: 60000, connect_timeout: 10000, ssl: [verify: :verify_none]]

        case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts, body_format: :binary) do
          {:ok, {{_, 200, _}, _, body}} ->
            File.write!(target_path, body)
            size = byte_size(body)
            if is_pid(caller_pid), do: send(caller_pid, {:update_download_progress, 100, size, size})
            {:ok, target_path}

          {:ok, {{_, status, _}, _, _}} ->
            {:error, "Download failed with HTTP #{status}"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
      else
        {:error, "HTTP client not available"}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, "Failed to decode update JSON response"}
    end
  rescue
    _ ->
      try do
        {:ok, :json.decode(body)}
      rescue
        _ -> {:error, "Failed to parse release payload"}
      end
  end

  defp classify_asset(name) do
    cond do
      String.ends_with?(name, ".exe") -> :installer
      String.ends_with?(name, ".zip") -> :zip
      String.ends_with?(name, ".tar.gz") or String.ends_with?(name, ".tgz") -> :tarball
      true -> :other
    end
  end

  @doc """
  Detects host operating system: `:windows`, `:linux`, `:macos`, or `:other`.
  """
  def detect_os do
    case :os.type() do
      {:win32, _} -> :windows
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      _ -> :other
    end
  end

  @doc """
  Selects the most suitable download asset for the target platform.
  """
  def select_platform_asset(assets, :windows) do
    Enum.find(assets, &String.ends_with?(&1.name, ".exe")) ||
      Enum.find(assets, &String.ends_with?(&1.name, ".zip")) ||
      List.first(assets)
  end

  def select_platform_asset(assets, :linux) do
    Enum.find(assets, &String.ends_with?(&1.name, ".tar.gz")) ||
      Enum.find(assets, &String.ends_with?(&1.name, ".zip")) ||
      List.first(assets)
  end

  def select_platform_asset(assets, _other) do
    List.first(assets)
  end

  @doc """
  Compares two semantic version strings (e.g. "0.0.2" > "0.0.1").
  """
  def version_greater?(v1, v2) do
    clean_v1 = String.trim_leading(to_string(v1), "v")
    clean_v2 = String.trim_leading(to_string(v2), "v")

    case {Version.parse(clean_v1), Version.parse(clean_v2)} do
      {{:ok, ver1}, {:ok, ver2}} ->
        Version.compare(ver1, ver2) == :gt

      _ ->
        clean_v1 > clean_v2
    end
  end
end
