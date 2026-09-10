defmodule SSHClient.SocketAPI do
  @moduledoc """
  Unix domain socket server exposing server states and monitoring data as JSON.

  Supported commands (send as JSON):
    - GET / empty: returns all server states
    - {"command": "get_server", "server_id": "..."}
    - {"command": "reload"}
    - {"command": "service_action", "server_id": "...", "service": "...", "type": "systemctl|docker|pm2", "action": "restart|stop"}
    - {"command": "get_logs", "server_id": "...", "lines": N}
  """

  use GenServer

  alias SSHClient.ServerManager
  alias SSHClient.ServerWorker
  alias SSHClient.ServiceAction
  alias SSHClient.SSH.PTYSession
  alias SSHClient.TerminalSupervisor

  @default_socket_path "/tmp/omarchy_server.sock"
  @name __MODULE__

  defstruct [
    :socket_path,
    :listen_socket,
    :acceptor_pid
  ]

  # Client API

  @doc """
  Starts the SocketAPI server on a Unix domain socket.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the default socket path.
  """
  def default_socket_path do
    System.get_env("OMARCHY_SERVER_SOCKET") || @default_socket_path
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    socket_path = Keyword.get(opts, :socket_path, default_socket_path())
    clean_existing_socket(socket_path)

    charlist_path = String.to_charlist(socket_path)

    socket_opts = [
      :binary,
      :local,
      {:ifaddr, {:local, charlist_path}},
      {:active, false},
      {:reuseaddr, true}
    ]

    case :gen_tcp.listen(0, socket_opts) do
      {:ok, listen_socket} ->
        state = %__MODULE__{
          socket_path: socket_path,
          listen_socket: listen_socket
        }

        acceptor_pid = spawn_link(fn -> accept_loop(listen_socket) end)
        {:ok, %{state | acceptor_pid: acceptor_pid}}

      {:error, reason} when reason in [:eafnosupport, :enotsup, :einval] ->
        # Unix domain sockets not supported on this OS (e.g. Windows)
        state = %__MODULE__{
          socket_path: nil,
          listen_socket: nil
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket, do: :gen_tcp.close(state.listen_socket)
    if state.socket_path, do: clean_existing_socket(state.socket_path)
    :ok
  end

  # Acceptor and Protocol Loop

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        spawn(fn -> handle_client(client_socket) end)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen_socket)
    end
  end

  defp handle_client(client_socket) do
    case :gen_tcp.recv(client_socket, 0, 500) do
      {:ok, data} ->
        case check_terminal_request(data) do
          {:terminal, server_id, opts} ->
            handle_terminal_bridge(client_socket, server_id, opts)

          :normal ->
            response = process_request(data)
            send_json_response(client_socket, response)
            :gen_tcp.close(client_socket)
        end

      {:error, :timeout} ->
        response = get_all_servers_response()
        send_json_response(client_socket, response)
        :gen_tcp.close(client_socket)

      {:error, _reason} ->
        :gen_tcp.close(client_socket)
    end
  end

  defp check_terminal_request(data) do
    trimmed = String.trim(data)

    if String.starts_with?(trimmed, "{") do
      case decode_json(trimmed) do
        {:ok, %{"command" => "open_terminal", "server_id" => server_id} = cmd} ->
          cols = Map.get(cmd, "cols", 80)
          rows = Map.get(cmd, "rows", 24)
          term = Map.get(cmd, "term", "xterm-256color")
          {:terminal, server_id, [cols: cols, rows: rows, term: term]}

        _ ->
          :normal
      end
    else
      :normal
    end
  end

  defp handle_terminal_bridge(socket, server_id, opts) do
    case ServerWorker.whereis(server_id) do
      pid when is_pid(pid) ->
        server = ServerWorker.get_server_config(pid)

        case TerminalSupervisor.start_session(server, [client_pid: self()] ++ opts) do
          {:ok, session_pid} ->
            receive do
              {:pty_connected, ^session_pid} ->
                send_json_response(socket, %{status: "ok", session: "connected"})
                :inet.setopts(socket, active: true)
                terminal_bridge_loop(socket, session_pid)

              {:pty_error, reason} ->
                send_json_response(socket, %{status: "error", error: inspect(reason)})
                :gen_tcp.close(socket)
            after
              15_000 ->
                send_json_response(socket, %{status: "error", error: "pty connection timeout"})
                :gen_tcp.close(socket)
            end

          {:error, reason} ->
            send_json_response(socket, %{status: "error", error: inspect(reason)})
            :gen_tcp.close(socket)
        end

      nil ->
        send_json_response(socket, %{
          status: "error",
          error: "server worker not found: #{server_id}"
        })

        :gen_tcp.close(socket)
    end
  end

  defp terminal_bridge_loop(socket, session_pid) do
    receive do
      {:tcp, ^socket, data} ->
        trimmed = String.trim(data)

        if String.starts_with?(trimmed, "{\"command\":\"resize_pty\"") or
             String.starts_with?(trimmed, "{\"command\": \"resize_pty\"") do
          case decode_json(trimmed) do
            {:ok, %{"command" => "resize_pty", "cols" => cols, "rows" => rows}} ->
              PTYSession.resize(session_pid, cols, rows)

            _ ->
              PTYSession.send_input(session_pid, data)
          end
        else
          PTYSession.send_input(session_pid, data)
        end

        terminal_bridge_loop(socket, session_pid)

      {:pty_data, ^session_pid, raw_bytes} ->
        :gen_tcp.send(socket, raw_bytes)
        terminal_bridge_loop(socket, session_pid)

      {:pty_eof, ^session_pid} ->
        :gen_tcp.close(socket)

      {:pty_exit, ^session_pid, _code} ->
        :gen_tcp.close(socket)

      {:pty_closed, ^session_pid} ->
        :gen_tcp.close(socket)

      {:tcp_closed, ^socket} ->
        PTYSession.close(session_pid)

      {:tcp_error, ^socket, _reason} ->
        PTYSession.close(session_pid)

      _other ->
        terminal_bridge_loop(socket, session_pid)
    end
  end

  defp process_request(data) when is_binary(data) do
    trimmed = String.trim(data)

    cond do
      trimmed == "" or trimmed == "GET" or String.starts_with?(trimmed, "GET ") ->
        get_all_servers_response()

      String.starts_with?(trimmed, "{") ->
        case decode_json(trimmed) do
          {:ok,
           %{
             "command" => "service_action",
             "server_id" => server_id,
             "service" => service,
             "type" => type,
             "action" => action
           } = cmd} ->
            case validate_service_action(action) do
              {:ok, safe_action} ->
                case ServerManager.get_server(server_id) do
                  {:ok, _server} ->
                    confirmed = Map.get(cmd, "confirmed", true)

                    case ServiceAction.run(server_id, service, type, safe_action,
                           confirmed: confirmed
                         ) do
                      {:ok, output} ->
                        %{
                          status: "ok",
                          output: output,
                          server_id: server_id,
                          service: service,
                          action: safe_action
                        }

                      {:error, reason} ->
                        %{status: "error", error: inspect(reason)}
                    end

                  {:error, :not_found} ->
                    %{status: "error", error: "server not found: #{server_id}"}

                  {:error, reason} ->
                    %{status: "error", error: to_string(reason)}
                end

              {:error, reason} ->
                %{status: "error", error: reason}
            end

          {:ok, %{"command" => "get_logs", "server_id" => server_id} = cmd} ->
            lines = Map.get(cmd, "lines", 50)
            journal_unit = Map.get(cmd, "unit")

            case ServiceAction.get_logs(server_id, lines, journal_unit) do
              {:ok, log_output} ->
                %{status: "ok", server_id: server_id, lines: lines, log: log_output}

              {:error, reason} ->
                %{status: "error", error: inspect(reason)}
            end

          {:ok, %{"command" => "get_server", "server_id" => id}} ->
            case ServerManager.get_server(id) do
              {:ok, server} -> %{status: "ok", server: serialize_server(server)}
              {:error, reason} -> %{status: "error", error: to_string(reason)}
            end

          {:ok, %{"command" => "reload"}} ->
            case ServerManager.sync_file() do
              {:ok, result} -> %{status: "ok", reloaded: true, summary: result}
              {:error, reason} -> %{status: "error", error: inspect(reason)}
            end

          {:ok, %{"command" => "add_server", "server" => server_map}} ->
            case ServerManager.add_server(server_map) do
              {:ok, result} -> %{status: "ok", server: result}
              {:error, reason} -> %{status: "error", error: inspect(reason)}
            end

          {:ok, %{"command" => "remove_server", "server_id" => server_id}} ->
            case ServerManager.remove_server(server_id) do
              {:ok, result} -> %{status: "ok", result: result}
              {:error, reason} -> %{status: "error", error: inspect(reason)}
            end

          {:ok, %{"command" => "poll_now", "server_id" => server_id}} ->
            case ServerWorker.whereis(server_id) do
              pid when is_pid(pid) ->
                case ServerWorker.poll_now(pid) do
                  {:ok, status} ->
                    state = ServerWorker.get_state(pid)

                    %{
                      status: "ok",
                      server_id: server_id,
                      worker_status: to_string(status),
                      server: serialize_server(state)
                    }

                  {:error, reason} ->
                    %{status: "error", error: inspect(reason)}
                end

              nil ->
                %{status: "error", error: "server worker not found: #{server_id}"}
            end

          {:ok, %{"command" => "poll_all"}} ->
            workers = ServerManager.get_workers()

            Enum.each(workers, fn {_id, pid} ->
              try do
                ServerWorker.poll_now(pid)
              rescue
                _ -> :ok
              catch
                :exit, _ -> :ok
              end
            end)

            get_all_servers_response()

          _ ->
            get_all_servers_response()
        end

      true ->
        get_all_servers_response()
    end
  end

  defp get_all_servers_response do
    servers =
      try do
        ServerManager.list_servers()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    serialized = Enum.map(servers, &serialize_server/1)

    %{
      status: "ok",
      servers: serialized,
      count: length(serialized),
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp serialize_server(server) when is_map(server) do
    %{
      id: to_string(server.id),
      name: to_string(server[:name] || server.id),
      host: to_string(server.host),
      status: to_string(server.status),
      metrics: server[:metrics] || %{},
      checks: server[:checks] || %{},
      init_system: if(server[:init_system], do: to_string(server[:init_system]), else: :null),
      last_error: if(server[:last_error], do: inspect(server[:last_error]), else: :null),
      updated_at:
        if(server[:updated_at], do: DateTime.to_iso8601(server[:updated_at]), else: :null)
    }
  end

  defp send_json_response(socket, response_map) do
    json_binary =
      response_map
      |> :json.encode()
      |> IO.iodata_to_binary()

    :gen_tcp.send(socket, [json_binary, "\n"])
  end

  defp decode_json(binary) do
    try do
      {:ok, :json.decode(binary)}
    rescue
      _ -> :error
    end
  end

  defp clean_existing_socket(path) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
    :ok
  end

  defp validate_service_action("restart"), do: {:ok, "restart"}
  defp validate_service_action("stop"), do: {:ok, "stop"}

  defp validate_service_action(other),
    do: {:error, "invalid action: #{other}. allowed: restart, stop"}
end
