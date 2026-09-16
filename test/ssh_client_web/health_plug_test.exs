defmodule SSHClientWeb.HealthPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  describe "GET /health through the endpoint" do
    test "returns 200 with body ok" do
      conn = call_endpoint(:get, "/health")

      assert conn.status == 200
      assert conn.resp_body == "ok"
      assert conn.halted
    end

    test "sets a text/plain content type" do
      conn = call_endpoint(:get, "/health")
      [content_type] = get_resp_header(conn, "content-type")

      assert String.starts_with?(content_type, "text/plain")
    end
  end

  describe "HealthPlug.call/2" do
    test "handles GET /health without reaching later plugs" do
      conn = conn(:get, "/health") |> SSHClientWeb.HealthPlug.call([])

      assert conn.status == 200
      assert conn.resp_body == "ok"
      assert conn.halted
    end

    test "passes GET /hosts through so LiveView can render" do
      conn = conn(:get, "/hosts") |> SSHClientWeb.HealthPlug.call([])

      assert conn.status == nil
      refute conn.halted
    end

    test "does not treat similar paths as healthy" do
      conn = conn(:get, "/healthz") |> SSHClientWeb.HealthPlug.call([])

      refute conn.halted
      assert conn.status == nil
    end

    test "does not handle POST /health" do
      conn = conn(:post, "/health") |> SSHClientWeb.HealthPlug.call([])

      refute conn.halted
      assert conn.status == nil
    end
  end

  describe "endpoint negative path" do
    test "GET /healthz is not the launcher health endpoint" do
      conn = call_endpoint(:get, "/healthz")

      refute conn.resp_body == "ok"
      assert conn.status in [404, 500]
    end
  end

  defp call_endpoint(method, path) do
    conn(method, path)
    |> Map.put(:host, "127.0.0.1")
    |> SSHClientWeb.Endpoint.call(SSHClientWeb.Endpoint.init([]))
  end
end
