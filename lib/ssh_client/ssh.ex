defmodule SSHClient.SSH do
  @moduledoc """
  SSH client wrapper built on OTP :ssh with ProxyJump support and typed error handling.
  """

  alias SSHClient.Config.Server
  alias SSHClient.Host
  alias SSHClient.Keychain
  alias SSHClient.SSH.Auth

  defmodule Connection do
    @moduledoc """
    Represents an active SSH connection, tracking channel and optional jump host tunnel.
    """
    defstruct [:conn_ref, :jump_ref, :jump_port, :server]
  end

  @type t :: %Connection{
          conn_ref: :ssh.connection_ref(),
          jump_ref: :ssh.connection_ref() | nil,
          jump_port: integer() | nil,
          server: Server.t() | map()
        }

  @type exec_result :: {:ok, String.t(), integer()} | {:error, term()}

  @doc """
  Parses a ProxyJump string into %{host: String.t(), port: integer(), user: String.t() | nil}.
  Supports formats:
  - "host"
  - "user@host"
  - "user@host:port"
  - "host:port"
  """
  @spec parse_proxy_jump(String.t() | nil) ::
          %{host: String.t(), port: integer(), user: String.t() | nil} | nil
  def parse_proxy_jump(nil), do: nil
  def parse_proxy_jump(""), do: nil

  def parse_proxy_jump(jump_str) when is_binary(jump_str) do
    {user, rest} =
      case String.split(jump_str, "@", parts: 2) do
        [u, r] -> {u, r}
        [r] -> {nil, r}
      end

    {host, port} =
      case String.split(rest, ":", parts: 2) do
        [h, p] ->
          case Integer.parse(p) do
            {parsed_port, ""} -> {h, parsed_port}
            _ -> {h, 22}
          end

        [h] ->
          {h, 22}
      end

    %{host: host, port: port, user: user}
  end

  @doc """
  Connects to a remote server using OTP :ssh, establishing a jump host tunnel if configured.
  Returns `{:ok, %Connection{}}` or `{:error, typed_error}`.
  """
  @spec connect(Host.t() | Server.t() | map(), keyword()) ::
          {:ok, Connection.t()} | {:error, term()}
  def connect(server_or_opts, opts \\ [])

  def connect(%Host{} = host, opts) do
    proxy_jump = host.jump_host
    do_connect(host, proxy_jump, opts)
  end

  def connect(%Server{} = server, opts) do
    proxy_jump = server.proxy_jump
    do_connect(server, proxy_jump, opts)
  end

  def connect(opts_map, opts) when is_map(opts_map) do
    proxy_jump = Map.get(opts_map, :proxy_jump) || Map.get(opts_map, "proxy_jump")
    do_connect(opts_map, proxy_jump, opts)
  end

  defp do_connect(target, nil, opts) do
    host = get_field(target, :host)
    port = get_field(target, :port, 22)
    user = Keyword.get(opts, :user) || get_field(target, :user)
    timeout = Keyword.get(opts, :timeout, 10_000)

    opts = resolve_keychain_password(target, user, opts)

    case connect_direct(target, host, port, user, timeout, opts) do
      {:ok, conn_ref} ->
        {:ok, %Connection{conn_ref: conn_ref, jump_ref: nil, jump_port: nil, server: target}}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  defp do_connect(target, proxy_jump, opts) do
    jump_info = parse_proxy_jump(proxy_jump)
    timeout = Keyword.get(opts, :timeout, 10_000)
    user = Keyword.get(opts, :user) || get_field(target, :user)
    opts = resolve_keychain_password(target, user, opts)

    case connect_direct(target, jump_info.host, jump_info.port, jump_info.user, timeout, opts) do
      {:ok, jump_ref} ->
        target_host = get_field(target, :host)
        target_port = get_field(target, :port, 22)
        target_host_charlist = String.to_charlist(target_host)

        case :ssh.tcpip_tunnel_to_server(
               jump_ref,
               ~c"127.0.0.1",
               0,
               target_host_charlist,
               target_port
             ) do
          {:ok, listen_port} ->
            case connect_direct(target, "127.0.0.1", listen_port, user, timeout, opts) do
              {:ok, conn_ref} ->
                {:ok,
                 %Connection{
                   conn_ref: conn_ref,
                   jump_ref: jump_ref,
                   jump_port: listen_port,
                   server: target
                 }}

              {:error, reason} ->
                :ssh.close(jump_ref)
                {:error, {:connection_failed, reason}}
            end

          {:error, reason} ->
            :ssh.close(jump_ref)
            {:error, {:jump_tunnel_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:jump_host_failed, reason}}
    end
  end

  defp resolve_keychain_password(target, user, opts) do
    case Keyword.get(opts, :password) do
      nil ->
        server_id = get_field(target, :id)

        if server_id && user do
          account = "#{user}@#{server_id}"

          case Keychain.retrieve(account) do
            {:ok, secret} when is_binary(secret) and secret != "" ->
              Keyword.put(opts, :password, secret)

            _ ->
              opts
          end
        else
          opts
        end

      _ ->
        opts
    end
  end

  defp connect_direct(target, host, port, user, timeout, opts) do
    host_charlist = ensure_charlist(host)
    ssh_opts = build_ssh_options(target, user, opts)

    try do
      :ssh.connect(host_charlist, port, ssh_opts, timeout)
    catch
      :exit, reason -> {:error, reason}
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp build_ssh_options(target, user, extra_opts) do
    silent = Keyword.get(extra_opts, :silently_accept_hosts, false)

    base = [
      key_cb: {SSHClient.SSH.KeyCallback, extra_opts},
      user_interaction: false
    ]

    base =
      if silent do
        [{:silently_accept_hosts, true} | base]
      else
        base
      end

    base =
      if user && user != "" do
        [{:user, ensure_charlist(user)} | base]
      else
        base
      end

    auth_opts = Auth.build_options(target, extra_opts)
    Keyword.merge(base, auth_opts)
  end

  @doc """
  Executes a command on an open SSH connection and awaits completion.
  Returns `{:ok, stdout, exit_status}` or `{:error, typed_reason}`.
  """
  @spec exec(Connection.t(), String.t(), keyword()) :: exec_result()
  def exec(%Connection{conn_ref: conn_ref}, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    with {:ok, channel_id} <- open_session(conn_ref, timeout),
         status when status in [:ok, :success] <-
           send_exec(conn_ref, channel_id, command, timeout) do
      collect_output(conn_ref, channel_id, timeout)
    else
      {:error, reason} -> {:error, {:exec_failed, reason}}
      other -> {:error, {:exec_failed, other}}
    end
  end

  defp open_session(conn_ref, timeout) do
    try do
      :ssh_connection.session_channel(conn_ref, timeout)
    catch
      :exit, reason -> {:error, reason}
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp send_exec(conn_ref, channel_id, command, timeout) do
    try do
      :ssh_connection.exec(conn_ref, channel_id, ensure_charlist(command), timeout)
    catch
      :exit, reason -> {:error, reason}
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @doc """
  Collects channel messages until the channel closes or reaches timeout.
  """
  @spec collect_output(term(), term(), non_neg_integer()) :: exec_result()
  def collect_output(conn_ref, channel_id, timeout) do
    do_collect(conn_ref, channel_id, [], 0, timeout)
  end

  defp do_collect(conn_ref, channel_id, acc, exit_code, timeout) do
    receive do
      {:ssh_cm, ^conn_ref, {:data, ^channel_id, _type, data}} ->
        do_collect(conn_ref, channel_id, [data | acc], exit_code, timeout)

      {:ssh_cm, ^conn_ref, {:exit_status, ^channel_id, status}} ->
        do_collect(conn_ref, channel_id, acc, status, timeout)

      {:ssh_cm, ^conn_ref, {:eof, ^channel_id}} ->
        do_collect(conn_ref, channel_id, acc, exit_code, timeout)

      {:ssh_cm, ^conn_ref, {:closed, ^channel_id}} ->
        full_output =
          acc
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        {:ok, full_output, exit_code}
    after
      timeout ->
        try do
          :ssh_connection.close(conn_ref, channel_id)
        catch
          _, _ -> :ok
        end

        {:error, :timeout}
    end
  end

  @doc """
  Closes an active SSH connection, its jump tunnel, and jump host connection if present.
  """
  @spec close(Connection.t() | term()) :: :ok
  def close(%Connection{conn_ref: conn_ref, jump_ref: jump_ref}) do
    if conn_ref, do: :ssh.close(conn_ref)
    if jump_ref, do: :ssh.close(jump_ref)
    :ok
  rescue
    _ -> :ok
  end

  def close(_), do: :ok

  @doc """
  Runs a command by opening a connection, executing the command, and closing the connection.
  """
  @spec run(Server.t() | map(), String.t(), keyword()) :: exec_result()
  def run(server_or_opts, command, opts \\ []) do
    case connect(server_or_opts, opts) do
      {:ok, conn} ->
        try do
          exec(conn, command, opts)
        after
          close(conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Opens an interactive pseudo-terminal (PTY) shell on the SSH connection.
  Returns `{:ok, channel_id}` or `{:error, reason}`.
  """
  @spec open_pty(Connection.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def open_pty(%Connection{conn_ref: conn_ref}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    term = ensure_charlist(Keyword.get(opts, :term, "xterm-256color"))

    with {:ok, channel_id} <- open_session(conn_ref, timeout),
         status when status in [:ok, :success] <-
           :ssh_connection.ptty_alloc(
             conn_ref,
             channel_id,
             [term: term, width: cols, height: rows],
             timeout
           ),
         shell_status when shell_status in [:ok, :success] <-
           :ssh_connection.shell(conn_ref, channel_id) do
      {:ok, channel_id}
    else
      {:error, reason} -> {:error, {:pty_failed, reason}}
      other -> {:error, {:pty_failed, other}}
    end
  end

  @doc """
  Sends raw binary input data to the PTY channel.
  """
  @spec send_pty_data(Connection.t(), term(), binary()) :: :ok | {:error, term()}
  def send_pty_data(%Connection{conn_ref: conn_ref}, channel_id, data) when is_binary(data) do
    case :ssh_connection.send(conn_ref, channel_id, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  @doc """
  Notifies the remote PTY of terminal window dimension changes.
  """
  @spec resize_pty(Connection.t(), term(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def resize_pty(%Connection{conn_ref: conn_ref}, channel_id, cols, rows)
      when is_integer(cols) and is_integer(rows) do
    case :ssh_connection.window_change(conn_ref, channel_id, cols, rows) do
      status when status in [:ok, :success] -> :ok
      {:error, reason} -> {:error, {:resize_failed, reason}}
      _ -> :ok
    end
  end

  @doc """
  Closes an active PTY channel.
  """
  @spec close_pty(Connection.t(), term()) :: :ok
  def close_pty(%Connection{conn_ref: conn_ref}, channel_id) do
    try do
      :ssh_connection.close(conn_ref, channel_id)
    catch
      _, _ -> :ok
    end

    :ok
  end

  @doc """
  Initiates a connect attempt that can be cancelled at any point via cancel_token or abort/1.
  Default timeout is 10,000ms (10 seconds).
  Returns `{:ok, connection}` or `{:error, {:timeout, "Connection timed out after Nms"}}` or `{:error, :cancelled}`.
  """
  @spec connect_cancelable(Host.t() | Server.t() | map(), keyword()) ::
          {:ok, Connection.t(), pid()} | {:error, term()}
  def connect_cancelable(target, opts \\ []) do
    _timeout = Keyword.get(opts, :timeout, 10_000)
    _parent = self()

    task =
      Task.async(fn ->
        connect(target, opts)
      end)

    {:ok, task}
  end

  @doc """
  Cancels an in-flight connect task.
  """
  def cancel_connect(%Task{} = task) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def cancel_connect(pid) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  def cancel_connect(_), do: :ok

  @doc """
  Awaits a cancelable connection attempt up to `timeout` milliseconds.
  Maps failures into plain-language human-readable explanations.
  """
  def await_connect(%Task{} = task, timeout \\ 10_000) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, conn}} ->
        {:ok, conn}

      {:ok, {:error, reason}} ->
        {:error, {reason, plain_language_error(reason)}}

      nil ->
        {:error, {:timeout, "Connection timed out after #{timeout}ms"}}

      {:exit, :killed} ->
        {:error, {:cancelled, "Connection attempt cancelled by user"}}

      {:exit, reason} ->
        {:error, {reason, plain_language_error(reason)}}
    end
  end

  @doc """
  Maps raw Erlang :ssh and network failure terms to plain-language reasons.
  """
  def plain_language_error(reason) do
    case reason do
      :timeout ->
        "Connection timed out. Remote host did not respond."

      {:timeout, _} ->
        "Connection timed out. Remote host did not respond."

      :econnrefused ->
        "Connection refused. Port is closed or SSH daemon is not running on remote host."

      :ehostunreach ->
        "Host unreachable. Check your network connection and server address."

      :enetunreach ->
        "Network unreachable. No route to the destination network."

      {:connection_failed, :econnrefused} ->
        "Connection refused. SSH service is not accepting connections on specified port."

      {:connection_failed, :ehostunreach} ->
        "Host unreachable. Check your network or firewall rules."

      {:connection_failed, :timeout} ->
        "Connection timed out. Remote host did not respond."

      {:connection_failed, {:auth_failed, _}} ->
        "Authentication rejected. Invalid password, key, or credentials."

      {:connection_failed, "Authentication failed."} ->
        "Authentication failed. Check your username, SSH key, or password."

      {:auth_failed, _} ->
        "Authentication rejected. Invalid password, key, or credentials."

      {:host_key_mismatch, _} ->
        "Host key mismatch! Potential man-in-the-middle attack or host key was rotated."

      {:host_key_changed, _} ->
        "Host key has changed! Please verify the fingerprint before continuing."

      {:jump_host_failed, _} ->
        "Failed to establish jump host bastion connection."

      other ->
        "Connection failed: #{inspect(other)}"
    end
  end

  defp get_field(map_or_struct, key, default \\ nil)

  defp get_field(%Host{} = h, :host, _), do: h.address
  defp get_field(%Host{} = h, :port, _), do: h.port || 22
  defp get_field(%Host{} = h, :user, _), do: h.user
  defp get_field(%Host{} = h, :proxy_jump, _), do: h.jump_host

  defp get_field(%Server{} = s, :host, _), do: s.host
  defp get_field(%Server{} = s, :port, _), do: s.port || 22
  defp get_field(%Server{} = s, :user, _), do: s.user
  defp get_field(%Server{} = s, :proxy_jump, _), do: s.proxy_jump

  defp get_field(m, key, default) when is_map(m) do
    Map.get(m, key) || Map.get(m, to_string(key)) || default
  end

  defp ensure_charlist(val) when is_binary(val), do: String.to_charlist(val)
  defp ensure_charlist(val) when is_list(val), do: val
end
