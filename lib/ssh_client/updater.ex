defmodule SSHClient.Updater do
  @moduledoc """
  Robust application updater for ssh-client.
  Provides update checking from GitHub Releases, multi-platform asset detection,
  in-app background downloading with progress reporting, automatic archive staging
  and extraction, and seamless zero-wizard in-place restart updates on Windows and Linux.
  """

  require Logger

  @current_version "0.0.8"
  @repo_owner "dineshkorukonda"
  @repo_name "ssh-client"
  @api_url "https://api.github.com/repos/#{@repo_owner}/#{@repo_name}/releases/latest"

  @doc """
  Returns the current running version of the application.
  """
  def current_version, do: @current_version

  @doc """
  Returns the staging cache directory used for background downloads and unpacks.
  """
  def staging_dir do
    base =
      try do
        SSHClient.Config.os_config_dir()
      rescue
        _ -> System.tmp_dir!()
      end

    Path.join(base, "staging")
  end

  @doc """
  Returns the root directory of the running application installation.
  In an OTP release, this points to the directory containing bin/, erts-*/, lib/, releases/.
  """
  def app_root_dir do
    case :code.root_dir() do
      dir when is_list(dir) ->
        dir_str = to_string(dir)
        Path.expand(dir_str)

      dir when is_binary(dir) ->
        Path.expand(dir)

      _ ->
        File.cwd!()
    end
  end

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
  Downloads and unpacks an update archive into the background staging directory.
  Streams download progress to caller_pid.
  Returns `{:ok, %{staged_dir: path, archive_path: path}}` or `{:error, reason}`.
  """
  def stage_in_place_update(asset_url, target_filename \\ nil, opts \\ []) do
    caller_pid = Keyword.get(opts, :caller_pid, self())
    filename = target_filename || Path.basename(asset_url)
    stage_base = staging_dir()
    download_dir = Path.join(stage_base, "download")
    unpacked_dir = Path.join(stage_base, "unpacked")

    File.mkdir_p!(download_dir)
    archive_path = Path.join(download_dir, filename)

    with {:ok, downloaded_file} <- download_file(asset_url, archive_path, caller_pid),
         :ok <- prepare_unpacked_dir(unpacked_dir),
         {:ok, staged_path} <- extract_archive(downloaded_file, unpacked_dir) do
      {:ok, %{staged_dir: staged_path, archive_path: downloaded_file}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_unpacked_dir(dir) do
    File.rm_rf(dir)
    File.mkdir_p(dir)
  end

  @doc """
  Extracts a .zip or .tar.gz archive into target destination directory.
  Uses native Erlang :zip and :erl_tar with PowerShell/tar fallback.
  """
  def extract_archive(archive_path, dest_dir) do
    if not File.exists?(archive_path) do
      {:error, "Archive file does not exist: #{archive_path}"}
    else
      File.mkdir_p!(dest_dir)
      ext = archive_path |> Path.extname() |> String.downcase()

      cond do
        ext == ".zip" ->
          extract_zip(archive_path, dest_dir)

        ext in [".gz", ".tgz", ".tar"] ->
          extract_tarball(archive_path, dest_dir)

        true ->
          {:error, "Unsupported archive format: #{ext}"}
      end
    end
  end

  defp extract_zip(archive_path, dest_dir) do
    char_archive = String.to_charlist(archive_path)
    char_dest = String.to_charlist(dest_dir)

    case :zip.extract(char_archive, [{:cwd, char_dest}]) do
      {:ok, _file_list} ->
        {:ok, dest_dir}

      {:error, reason} ->
        if detect_os() == :windows and System.find_executable("powershell") != nil do
          script = "Expand-Archive -Path '#{archive_path}' -DestinationPath '#{dest_dir}' -Force"

          case System.cmd("powershell", ["-NoProfile", "-Command", script]) do
            {_, 0} -> {:ok, dest_dir}
            {err, _} -> {:error, "ZIP extraction failed: #{inspect(reason)} / #{err}"}
          end
        else
          {:error, "ZIP extraction failed: #{inspect(reason)}"}
        end
    end
  rescue
    e -> {:error, "ZIP extraction exception: #{Exception.message(e)}"}
  end

  defp extract_tarball(archive_path, dest_dir) do
    char_archive = String.to_charlist(archive_path)
    char_dest = String.to_charlist(dest_dir)

    case :erl_tar.extract(char_archive, [:compressed, {:cwd, char_dest}]) do
      :ok ->
        {:ok, dest_dir}

      {:error, reason} ->
        case System.cmd("tar", ["-xzf", archive_path, "-C", dest_dir]) do
          {_, 0} -> {:ok, dest_dir}
          {err, _} -> {:error, "Tarball extraction failed: #{inspect(reason)} / #{err}"}
        end
    end
  rescue
    e -> {:error, "Tarball extraction exception: #{Exception.message(e)}"}
  end

  @doc """
  Generates a detached update script, launches it in the background,
  and cleanly stops the application to release all file locks and restart into the new version.
  """
  def apply_update_and_restart(staged_dir \\ nil, target_dir \\ nil) do
    staged = staged_dir || Path.join(staging_dir(), "unpacked")
    target = target_dir || app_root_dir()

    if not File.exists?(staged) do
      {:error, "Staged update directory not found: #{staged}"}
    else
      os = detect_os()
      current_pid = System.pid()

      case os do
        :windows ->
          apply_update_windows(staged, target, current_pid)

        :linux ->
          apply_update_linux(staged, target, current_pid)

        _ ->
          {:error, "Unsupported platform for automatic in-place restart."}
      end
    end
  end

  defp apply_update_windows(staged_dir, target_dir, current_pid) do
    script_dir = staging_dir()
    File.mkdir_p!(script_dir)
    bat_path = Path.join(script_dir, "apply_update.bat")
    vbs_path = Path.join(script_dir, "apply_update.vbs")

    win_staged = String.replace(staged_dir, "/", "\\")
    win_target = String.replace(target_dir, "/", "\\")

    bat_content = """
    @echo off
    setlocal enabledelayedexpansion

    :: 1. Wait for parent process to cleanly exit and release file locks
    timeout /t 2 /nobreak >nul
    if not "#{current_pid}"=="" (
        taskkill /PID #{current_pid} /F >nul 2>&1
    )

    :: Kill any remaining background beam processes
    taskkill /F /IM werl.exe >nul 2>&1
    taskkill /F /IM beam.smp >nul 2>&1

    :: 2. Copy staged release files into the application directory
    robocopy "#{win_staged}" "#{win_target}" /E /IS /IT /MOVE /R:3 /W:1 >nul 2>&1
    if errorlevel 8 (
        xcopy "#{win_staged}\\*" "#{win_target}\\" /E /Y /I /Q >nul 2>&1
    )

    :: 3. Clean up staging folder
    rmdir /S /Q "#{win_staged}" >nul 2>&1

    :: 4. Relaunch ssh-client
    if exist "#{win_target}\\bin\\launch-gui.vbs" (
        start "" wscript.exe "#{win_target}\\bin\\launch-gui.vbs"
    ) else if exist "#{win_target}\\bin\\launch-gui.bat" (
        start "" "#{win_target}\\bin\\launch-gui.bat"
    ) else if exist "#{win_target}\\bin\\ssh_client.bat" (
        start "" "#{win_target}\\bin\\ssh_client.bat" start
    )

    exit /b 0
    """

    vbs_content = """
    Set WshShell = CreateObject("WScript.Shell")
    WshShell.Run "cmd /c \"\"" & WScript.Arguments(0) & "\"\"", 0, False
    """

    File.write!(bat_path, bat_content)
    File.write!(vbs_path, vbs_content)

    try do
      System.cmd("wscript.exe", [vbs_path, bat_path], spawn_opt: [:detached])
    rescue
      _ ->
        System.cmd("cmd.exe", ["/c", "start", "", "/b", bat_path], spawn_opt: [:detached])
    end

    schedule_vm_shutdown()

    {:ok, :restarting, "Update script launched. ssh-client is restarting into the new version."}
  end

  defp apply_update_linux(staged_dir, target_dir, current_pid) do
    script_dir = staging_dir()
    File.mkdir_p!(script_dir)
    sh_path = Path.join(script_dir, "apply_update.sh")

    sh_content = """
    #!/bin/sh
    sleep 1
    if [ -n "#{current_pid}" ]; then
        kill -9 #{current_pid} 2>/dev/null || true
    fi

    cp -rf "#{staged_dir}"/* "#{target_dir}"/
    rm -rf "#{staged_dir}"

    if [ -f "#{target_dir}/bin/ssh_client" ]; then
        "#{target_dir}/bin/ssh_client" daemon &
    fi
    """

    File.write!(sh_path, sh_content)
    File.chmod!(sh_path, 0o755)

    try do
      System.cmd("sh", [sh_path], spawn_opt: [:detached])
    rescue
      _ -> :ok
    end

    schedule_vm_shutdown()

    {:ok, :restarting, "Update script launched. ssh-client is restarting into the new version."}
  end

  defp schedule_vm_shutdown do
    Task.start(fn ->
      Process.sleep(400)
      System.stop(0)
    end)
  end

  @doc """
  Installs or executes the downloaded update package.
  On Windows: launches .exe installer silently or unpacks archive.
  On Linux: unpacks tarball or stages update.
  """
  def install_update(file_path) do
    if not File.exists?(file_path) do
      {:error, "Downloaded update file not found at: #{file_path}"}
    else
      ext = file_path |> Path.extname() |> String.downcase()

      case {detect_os(), ext} do
        {:windows, ".exe"} ->
          target_dir = app_root_dir()
          args = [
            "/c",
            "start",
            "",
            file_path,
            "/VERYSILENT",
            "/SUPPRESSMSGBOXES",
            "/NORESTART",
            "/CLOSEAPPLICATIONS",
            "/FORCECLOSEAPPLICATIONS",
            "/DIR=#{target_dir}"
          ]

          case System.cmd("cmd.exe", args) do
            {_, 0} ->
              {:ok, :installer_launched,
               "Windows Setup running silently in background. ssh-client will update and restart."}

            {err, code} ->
              {:error, "Failed to launch installer (code #{code}): #{err}"}
          end

        {:windows, ".zip"} ->
          dest = Path.join(staging_dir(), "unpacked")

          case extract_archive(file_path, dest) do
            {:ok, path} ->
              {:ok, :ready_to_restart, "Update archive extracted to #{path}. Ready to restart."}

            {:error, reason} ->
              {:error, reason}
          end

        {:linux, ext} when ext in [".gz", ".tgz", ".tar"] ->
          dest = Path.join(staging_dir(), "unpacked")

          case extract_archive(file_path, dest) do
            {:ok, path} ->
              {:ok, :ready_to_restart, "Update archive extracted to #{path}. Ready to restart."}

            {:error, reason} ->
              {:error, reason}
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
      case System.cmd("curl", [
             "-s",
             "-L",
             "-H",
             "User-Agent: ssh-client/#{@current_version}",
             "-H",
             "Accept: application/vnd.github.v3+json",
             url
           ]) do
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
      script =
        "$ProgressPreference = 'SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (Invoke-WebRequest -Uri '#{url}' -Headers @{'User-Agent'='ssh-client/#{@current_version}'; 'Accept'='application/vnd.github.v3+json'} -UseBasicParsing).Content"

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

    script =
      "$ProgressPreference = 'SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '#{url}' -OutFile '#{target_path}' -UseBasicParsing"

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
  Prefers portable ZIP archives on Windows and Tarballs on Linux for seamless in-place auto-update.
  """
  def select_platform_asset(assets, :windows) do
    Enum.find(assets, &String.ends_with?(&1.name, "-windows-x64.zip")) ||
      Enum.find(assets, &String.ends_with?(&1.name, ".zip")) ||
      Enum.find(assets, &String.ends_with?(&1.name, ".exe")) ||
      List.first(assets)
  end

  def select_platform_asset(assets, :linux) do
    Enum.find(assets, &String.ends_with?(&1.name, "-linux-x64.tar.gz")) ||
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
