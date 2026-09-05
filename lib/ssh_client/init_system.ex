defmodule SSHClient.InitSystem do
  @moduledoc """
  Probes and caches the init system used by a remote host over SSH.
  Supported init systems: :systemd, :openrc, :sysvinit, and :unsupported.
  """

  @table_name :ssh_client_init_systems

  @type t :: :systemd | :openrc | :sysvinit | :unsupported

  @probe_command "sh -c 'if [ -d /run/systemd/system ]; then echo systemd; elif [ -d /run/openrc ] || [ -f /run/openrc/softlevel ]; then echo openrc; elif [ -f /etc/init.d/rc ] || [ -f /etc/inittab ]; then echo sysvinit; else pid1=$(ps -p 1 -o comm= 2>/dev/null); case \"$pid1\" in *systemd*) echo systemd;; *init*) echo sysvinit;; *openrc*) echo openrc;; *) echo unsupported;; esac; fi'"

  @doc """
  Returns the shell probe command string.
  """
  @spec probe_command() :: String.t()
  def probe_command, do: @probe_command

  @doc """
  Ensures the ETS cache table exists.
  """
  @spec init_cache() :: :ok
  def init_cache do
    case :ets.whereis(@table_name) do
      :undefined ->
        try do
          :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end

  @doc """
  Retrieves a cached init system by server ID.
  """
  @spec get_cached(String.t()) :: {:ok, t()} | :error
  def get_cached(server_id) when is_binary(server_id) do
    init_cache()

    case :ets.lookup(@table_name, server_id) do
      [{^server_id, init_system}] -> {:ok, init_system}
      [] -> :error
    end
  end

  @doc """
  Stores the init system for a server ID into the cache.
  """
  @spec put_cached(String.t(), t()) :: :ok
  def put_cached(server_id, init_system) when is_binary(server_id) and is_atom(init_system) do
    init_cache()
    :ets.insert(@table_name, {server_id, init_system})
    :ok
  end

  @doc """
  Clears the entire init system cache.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    init_cache()
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Probes a remote host via a runner function or an SSH session.
  If server_id is provided, returns cached state when available, or saves the result to cache.
  """
  @spec detect(
          (String.t() -> {:ok, String.t(), integer()} | {:ok, String.t()} | {:error, term()})
          | term(),
          String.t() | nil
        ) :: {:ok, t()} | {:error, term()}
  def detect(runner_or_session, server_id \\ nil)

  def detect(runner, server_id) when is_function(runner, 1) do
    if is_binary(server_id) do
      case get_cached(server_id) do
        {:ok, cached} -> {:ok, cached}
        :error -> do_probe_and_cache(runner, server_id)
      end
    else
      do_probe(runner)
    end
  end

  def detect(session, server_id) do
    runner = fn cmd ->
      ssh_module = Application.get_env(:ssh_client, :ssh_client, SSHClient.SSH)

      if Code.ensure_loaded?(ssh_module) and
           function_exported?(ssh_module, :exec, 2) do
        apply(ssh_module, :exec, [session, cmd])
      else
        {:error, :no_ssh_runner_available}
      end
    end

    detect(runner, server_id)
  end

  defp do_probe_and_cache(runner, server_id) do
    case do_probe(runner) do
      {:ok, init_system} ->
        put_cached(server_id, init_system)
        {:ok, init_system}

      error ->
        error
    end
  end

  defp do_probe(runner) do
    case runner.(@probe_command) do
      {:ok, output, _exit_code} ->
        {:ok, parse(output)}

      {:ok, output} when is_binary(output) ->
        {:ok, parse(output)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses raw probe command output into a known init system atom.
  Falls back gracefully to `:unsupported`.
  """
  @spec parse(String.t() | nil) :: t()
  def parse(output) when is_binary(output) do
    trimmed =
      output
      |> String.trim()
      |> String.downcase()

    cond do
      String.contains?(trimmed, "systemd") -> :systemd
      String.contains?(trimmed, "openrc") -> :openrc
      String.contains?(trimmed, "sysvinit") -> :sysvinit
      true -> :unsupported
    end
  end

  def parse(_other), do: :unsupported
end
