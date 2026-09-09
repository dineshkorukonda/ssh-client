defmodule SSHClient.Diagnostics do
  @moduledoc """
  Redacted diagnostics export for crash reports. Never includes passwords or keys.
  """

  @secret_keys ~w(password passphrase secret token private_key identity contents key)

  def redact(value), do: do_redact(value)

  def snapshot do
    %{
      version: SSHClient.Updater.current_version(),
      os: inspect(:os.type()),
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> to_string(),
      sessions: safe_sessions(),
      hosts: safe_hosts()
    }
  end

  def export_json do
    snapshot()
    |> redact()
    |> Jason.encode!(pretty: true)
  end

  defp safe_sessions do
    try do
      SSHClient.SessionManager.list_sessions()
      |> Enum.map(fn s ->
        %{
          session_id: s.session_id,
          status: s.status,
          host: s.server && (s.server.id || s.server[:id])
        }
      end)
    rescue
      _ -> []
    end
  end

  defp safe_hosts do
    try do
      SSHClient.ServerManager.list_servers()
      |> Enum.map(fn s -> %{id: s[:id], host: s[:host], status: s[:status]} end)
    rescue
      _ -> []
    end
  end

  defp do_redact(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = to_string(k)

      if secret_key?(key) do
        {k, "[REDACTED]"}
      else
        {k, do_redact(v)}
      end
    end)
  end

  defp do_redact(list) when is_list(list), do: Enum.map(list, &do_redact/1)
  defp do_redact(other), do: other

  defp secret_key?(key) do
    down = String.downcase(key)
    Enum.any?(@secret_keys, &String.contains?(down, &1))
  end
end
