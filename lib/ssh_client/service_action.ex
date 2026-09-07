defmodule SSHClient.ServiceAction do
  @moduledoc """
  Executes service management actions (restart, stop) and log retrieval on
  remote servers via the existing ServerWorker SSH connection.

  Supported actions: restart, stop.
  Supported service types: systemctl, docker, pm2.
  """

  alias SSHClient.ServerWorker

  @allowed_actions ["restart", "stop"]
  @allowed_types ["systemctl", "docker", "pm2"]

  @doc """
  Runs a service action on the target server.
  Requires `confirmed: true` option for destructive actions (e.g. stop/restart).

  Looks up the running ServerWorker for `server_id` and executes the action
  command over its SSH connection via the worker's runner. Returns the command
  output on success.
  """
  @spec run(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run(server_id, service, type, action, opts \\ [])

  def run(server_id, service, type, action, opts)
      when action in @allowed_actions and type in @allowed_types do
    confirmed = Keyword.get(opts, :confirmed, false)

    if not confirmed do
      {:error, :confirmation_required}
    else
      safe_service = sanitize_name(service)

      case build_action_command(type, safe_service, action) do
        {:ok, cmd} ->
          target = ServerWorker.resolve_worker_pub(server_id)

          try do
            case GenServer.call(target, {:exec_cmd, cmd}, 15_000) do
              {:ok, output} -> {:ok, output}
              {:error, reason} -> {:error, reason}
            end
          catch
            :exit, {:noproc, _} -> {:error, :server_not_connected}
            :exit, {:normal, _} -> {:error, :server_not_connected}
            :exit, reason -> {:error, {:exec_failed, reason}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def run(_server_id, _service, type, action, _opts) do
    cond do
      action not in @allowed_actions ->
        {:error, "unsupported action: #{action}"}

      type not in @allowed_types ->
        {:error, "unsupported service type: #{type}"}

      true ->
        {:error, "invalid arguments"}
    end
  end

  @doc """
  Retrieves the last `lines` lines of system journal logs for a server.
  If `unit` is given, fetches logs for that specific systemd unit.
  Falls back to /var/log/syslog if journalctl is unavailable.
  """
  @spec get_logs(String.t(), pos_integer(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def get_logs(server_id, lines \\ 50, unit \\ nil) when is_integer(lines) and lines > 0 do
    safe_lines = min(lines, 500)

    cmd =
      if unit do
        safe_unit = sanitize_name(unit)

        "sh -c 'if command -v journalctl >/dev/null 2>&1; then " <>
          "journalctl -u #{safe_unit} -n #{safe_lines} --no-pager 2>/dev/null || true; " <>
          "else tail -n #{safe_lines} /var/log/syslog 2>/dev/null || echo unavailable; fi'"
      else
        "sh -c 'if command -v journalctl >/dev/null 2>&1; then " <>
          "journalctl -n #{safe_lines} --no-pager 2>/dev/null || true; " <>
          "else tail -n #{safe_lines} /var/log/syslog 2>/dev/null || echo unavailable; fi'"
      end

    target = ServerWorker.resolve_worker_pub(server_id)

    try do
      GenServer.call(target, {:exec_cmd, cmd}, 20_000)
    catch
      :exit, {:noproc, _} -> {:error, :server_not_connected}
      :exit, {:normal, _} -> {:error, :server_not_connected}
      :exit, reason -> {:error, {:exec_failed, reason}}
    end
  end

  @doc """
  Tails system journal or syslog continuously over an active SSH session,
  streaming chunks to the client PID as `{:log_chunk, server_id, binary()}`.
  """
  @spec tail_logs(String.t(), pos_integer(), String.t() | nil, pid()) ::
          {:ok, pid()} | {:error, term()}
  def tail_logs(server_id, lines \\ 50, unit \\ nil, client_pid \\ self()) do
    safe_lines = min(lines, 500)

    cmd =
      if unit do
        safe_unit = sanitize_name(unit)
        "journalctl -u #{safe_unit} -n #{safe_lines} -f --no-pager 2>/dev/null"
      else
        "journalctl -n #{safe_lines} -f --no-pager 2>/dev/null"
      end

    target = ServerWorker.resolve_worker_pub(server_id)

    Task.start(fn ->
      case GenServer.call(target, {:exec_cmd, cmd}, 60_000) do
        {:ok, output} ->
          send(client_pid, {:log_chunk, server_id, output})

        {:error, reason} ->
          send(client_pid, {:log_error, server_id, reason})
      end
    end)
  end

  # Builds the shell command for the given service type, name, and action.
  defp build_action_command("systemctl", service, action) do
    cmd =
      "sh -c 'if ! command -v systemctl >/dev/null 2>&1; then echo tool_missing; exit 1; fi; " <>
        "systemctl #{action} \"#{service}\" 2>&1; echo exit_code:$?'"

    {:ok, cmd}
  end

  defp build_action_command("docker", service, "restart") do
    cmd =
      "sh -c 'if ! command -v docker >/dev/null 2>&1; then echo tool_missing; exit 1; fi; " <>
        "docker restart \"#{service}\" 2>&1; echo exit_code:$?'"

    {:ok, cmd}
  end

  defp build_action_command("docker", service, "stop") do
    cmd =
      "sh -c 'if ! command -v docker >/dev/null 2>&1; then echo tool_missing; exit 1; fi; " <>
        "docker stop \"#{service}\" 2>&1; echo exit_code:$?'"

    {:ok, cmd}
  end

  defp build_action_command("pm2", service, "restart") do
    cmd =
      "sh -c 'if ! command -v pm2 >/dev/null 2>&1; then echo tool_missing; exit 1; fi; " <>
        "pm2 restart \"#{service}\" 2>&1; echo exit_code:$?'"

    {:ok, cmd}
  end

  defp build_action_command("pm2", service, "stop") do
    cmd =
      "sh -c 'if ! command -v pm2 >/dev/null 2>&1; then echo tool_missing; exit 1; fi; " <>
        "pm2 stop \"#{service}\" 2>&1; echo exit_code:$?'"

    {:ok, cmd}
  end

  defp build_action_command(type, _service, action) do
    {:error, "unsupported combination: type=#{type} action=#{action}"}
  end

  defp sanitize_name(name) do
    String.replace(name, ~r/[^\w\.\-\@\:\/]/, "")
  end
end
