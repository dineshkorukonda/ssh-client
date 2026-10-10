defmodule SSHClientWeb.DesktopAPITest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  @token String.duplicate("t", 64)

  setup do
    original = Application.get_env(:ssh_client, :desktop_token)
    Application.put_env(:ssh_client, :desktop_token, @token)
    original_path = System.get_env("SSH_CLIENT_SERVERS_CONFIG")
    path = Path.join(System.tmp_dir!(), "native-hosts-#{System.unique_integer([:positive])}.json")
    System.put_env("SSH_CLIENT_SERVERS_CONFIG", path)

    on_exit(fn ->
      if original,
        do: Application.put_env(:ssh_client, :desktop_token, original),
        else: Application.delete_env(:ssh_client, :desktop_token)

      if original_path,
        do: System.put_env("SSH_CLIENT_SERVERS_CONFIG", original_path),
        else: System.delete_env("SSH_CLIENT_SERVERS_CONFIG")

      File.rm(path)
    end)

    :ok
  end

  defp request(method, path, body \\ nil, headers \\ []) do
    conn(method, "/desktop/v1" <> path, if(body, do: Jason.encode!(body), else: ""))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> @token)
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> Map.put(:host, "127.0.0.1")
    |> SSHClientWeb.Endpoint.call(SSHClientWeb.Endpoint.init([]))
  end

  test "authenticated readiness identifies this backend; browser origins and remote clients are denied" do
    assert request(:get, "/health").status == 200
    assert request(:get, "/health", nil, [{"authorization", "Bearer wrong"}]).status == 401
    assert request(:get, "/health", nil, [{"origin", "https://untrusted.example"}]).status == 401

    conn =
      conn(:get, "/health")
      |> put_req_header("authorization", "Bearer " <> @token)
      |> Map.put(:remote_ip, {10, 0, 0, 1})

    assert SSHClientWeb.DesktopAPI.call(conn, []).status == 401
    Application.delete_env(:ssh_client, :desktop_token)
    assert request(:get, "/health").status == 401
  end

  test "native host operations preserve configuration and never persist passwords" do
    credential = Base.encode64(:crypto.strong_rand_bytes(24))

    attrs = %{
      id: "native",
      name: "Native host",
      host: "127.0.0.1",
      user: "fixture",
      port: 2222,
      password: credential
    }

    assert request(:post, "/hosts", attrs).status == 200
    conn = request(:get, "/hosts")
    assert [%{"id" => "native"}] = Jason.decode!(conn.resp_body)
    refute File.read!(SSHClient.Config.default_config_path()) =~ credential
    assert request(:delete, "/hosts/native").status == 200
    assert request(:get, "/hosts").resp_body == "[]"
  end

  test "invalid session dimensions, cursor, settings and file paths fail before dispatch" do
    assert request(:post, "/sessions/missing/resize", %{cols: -1, rows: 24}).status == 422
    assert request(:get, "/sessions/missing?since=invalid").status == 422
    assert request(:post, "/settings", %{font_size: 999, scrollback: 1000}).status == 422
    assert request(:post, "/files/missing/upload", %{path: %{bad: true}}).status == 422
  end
end
