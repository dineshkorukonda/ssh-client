defmodule SSHClient.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias SSHClient.Diagnostics

  test "redacts password token and key fields recursively" do
    input = %{
      host: "10.0.0.1",
      password: "secret-value",
      nested: %{auth_token: "abc", user: "root"},
      items: [%{private_key: "-----BEGIN", name: "id"}]
    }

    redacted = Diagnostics.redact(input)

    assert redacted.host == "10.0.0.1"
    assert redacted.password == "[REDACTED]"
    assert redacted.nested.auth_token == "[REDACTED]"
    assert redacted.nested.user == "root"
    assert hd(redacted.items).private_key == "[REDACTED]"
    assert hd(redacted.items).name == "id"
  end

  test "export_json is valid JSON without obvious secrets" do
    json = Diagnostics.export_json()
    assert {:ok, map} = Jason.decode(json)
    assert is_binary(map["version"]) or is_binary(map[:version]) or Map.has_key?(map, "version")
    refute json =~ "BEGIN OPENSSH PRIVATE KEY"
  end
end
