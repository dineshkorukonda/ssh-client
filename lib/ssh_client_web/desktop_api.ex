defmodule SSHClientWeb.DesktopAPI do
  @moduledoc "Versioned local API, available only with the native launcher's per-process token."
  use Plug.Router
  alias SSHClient.Desktop
  plug :authorize
  plug :match
  plug :dispatch

  defp authorize(conn, _) do
    token = Application.get_env(:ssh_client, :desktop_token)
    supplied = get_req_header(conn, "authorization")
    loopback = conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

    if loopback and is_binary(token) and byte_size(token) >= 32 and
         get_req_header(conn, "origin") == [] and supplied == ["Bearer " <> token] do
      conn
    else
      conn |> respond(401, %{error: "Unauthorized desktop request"}) |> halt()
    end
  end

  get "/health" do
    ready =
      Enum.all?(
        [SSHClient.SessionManager, SSHClient.Store, SSHClient.SFTP.TransferManager],
        &is_pid(Process.whereis(&1))
      )

    respond(conn, 200, %{
      ready: ready,
      api_version: 1,
      version: SSHClient.Updater.current_version()
    })
  end

  get "/hosts" do
    result(conn, Desktop.hosts())
  end

  get "/keys" do
    result(conn, {:ok, SSHClient.DesktopKeys.list()})
  end

  post "/keys" do
    result(conn, SSHClient.DesktopKeys.register(conn.body_params))
  end

  post "/keys/generate" do
    result(conn, SSHClient.DesktopKeys.generate(conn.body_params))
  end

  delete "/keys/:id" do
    result(conn, SSHClient.DesktopKeys.remove(id))
  end

  post "/hosts" do
    result(conn, Desktop.save_host(conn.body_params))
  end

  delete "/hosts/:id" do
    result(conn, Desktop.delete_host(id))
  end

  post "/sessions" do
    case Desktop.open_session(conn.body_params) do
      {:ok, id} -> respond(conn, 201, %{session_id: id})
      error -> result(conn, error)
    end
  end

  get "/sessions/:id" do
    conn = fetch_query_params(conn)

    case Integer.parse(conn.query_params["since"] || "0") do
      {since, ""} when since >= 0 -> result(conn, Desktop.session(id, since))
      _ -> result(conn, {:error, :invalid_cursor})
    end
  end

  delete "/sessions/:id" do
    result(conn, SSHClient.SessionManager.close_session(id))
  end

  post "/sessions/:id/:action" do
    attrs = conn.body_params

    valid =
      case action do
        "input" ->
          is_binary(attrs["data"]) and byte_size(attrs["data"]) <= 65_536

        "resize" ->
          is_integer(attrs["cols"]) and attrs["cols"] in 1..1000 and is_integer(attrs["rows"]) and
            attrs["rows"] in 1..1000

        "answer" ->
          is_binary(attrs["challenge"]) and is_list(attrs["answers"]) and
            length(attrs["answers"]) <= 20 and
            Enum.all?(attrs["answers"], &(is_binary(&1) and byte_size(&1) <= 4096))

        _ ->
          action in ~w(trust disconnect reconnect)
      end

    if valid,
      do: result(conn, Desktop.session_action(id, action, attrs)),
      else: result(conn, {:error, :invalid_action})
  end

  post "/files/:id/:action" do
    attrs = conn.body_params
    paths = Enum.map(["path", "local_path", "new_path"], &attrs[&1])

    if Enum.all?(paths, &(is_nil(&1) or (is_binary(&1) and byte_size(&1) <= 4096))) do
      result(conn, Desktop.files(id, action, attrs))
    else
      result(conn, {:error, :invalid_path})
    end
  end

  get "/transfers" do
    transfers = SSHClient.SFTP.TransferManager.list_transfers()

    result(
      conn,
      {:ok,
       Enum.map(
         transfers,
         &Map.take(&1, [
           :id,
           :session_id,
           :filename,
           :direction,
           :status,
           :progress,
           :bytes_transferred,
           :total_bytes,
           :speed_bps,
           :eta_seconds,
           :error
         ])
       )}
    )
  end

  post "/transfers/:id/:action" do
    manager = SSHClient.SFTP.TransferManager
    attrs = conn.body_params

    response =
      case action do
        "cancel" ->
          manager.cancel_transfer(id)

        "retry" ->
          manager.retry_transfer(id)

        direction when direction in ["upload", "download"] ->
          if is_binary(attrs["path"]) and is_binary(attrs["local_path"]) and
               byte_size(attrs["path"]) in 1..4096 and byte_size(attrs["local_path"]) in 1..4096 do
            with {:ok, worker} <- SSHClient.SessionManager.get_session(id),
                 {:ok, _} <- SSHClient.SessionWorker.connection(worker) do
              if direction == "upload",
                do: manager.queue_session_upload(id, attrs["local_path"], attrs["path"]),
                else: manager.queue_session_download(id, attrs["path"], attrs["local_path"])
            end
          else
            {:error, :invalid_path}
          end

        _ ->
          {:error, :invalid_action}
      end

    result(conn, response)
  end

  get "/settings" do
    result(conn, {:ok, Desktop.settings()})
  end

  post "/settings" do
    attrs = conn.body_params

    if is_integer(attrs["font_size"]) and attrs["font_size"] in 8..32 and
         is_integer(attrs["scrollback"]) and attrs["scrollback"] in 100..100_000 do
      result(conn, Desktop.save_settings(attrs))
    else
      result(conn, {:error, :invalid_settings})
    end
  end

  post "/backup" do
    result(conn, Desktop.backup())
  end

  get "/workspace" do
    result(conn, {:ok, Desktop.workspace()})
  end

  get "/workspaces" do
    result(conn, {:ok, Desktop.workspaces()})
  end

  post "/workspace" do
    ids = conn.body_params["host_ids"]

    if is_list(ids) and length(ids) <= 100 and
         Enum.all?(ids, &(is_binary(&1) and byte_size(&1) <= 4096)),
       do: result(conn, Desktop.save_workspace(conn.body_params)),
       else: result(conn, {:error, :invalid_workspace})
  end

  match _ do
    respond(conn, 404, %{error: "Unknown desktop endpoint"})
  end

  defp result(conn, :ok), do: respond(conn, 200, %{ok: true})
  defp result(conn, {:ok, data}), do: respond(conn, 200, data)

  defp result(conn, {:error, reason}),
    do: respond(conn, 422, %{error: SSHClient.SSH.plain_language_error(reason)})

  defp respond(conn, status, data) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
