defmodule SSHClient.DatabasePathTest do
  use ExUnit.Case, async: true

  alias SSHClient.DatabasePath

  test "default path uses the OS-specific application config directory" do
    assert DatabasePath.default_path() ==
             Path.join(SSHClient.Config.os_config_dir(), "terminal_workspaces.db")
  end

  test "environment path is expanded for portable installations" do
    path = Path.join([".", "tmp", "portable-workspaces.db"])

    assert DatabasePath.resolve(%{"SSH_CLIENT_DATABASE_PATH" => path}) == Path.expand(path)
  end

  test "test configuration uses an isolated temporary database" do
    configured_path = Application.fetch_env!(:ssh_client, SSHClient.Repo)[:database]

    assert Path.expand(Path.dirname(configured_path)) == Path.expand(System.tmp_dir!())
    assert Path.basename(configured_path) =~ ~r/^ssh_client_test_.+\.db$/
    refute configured_path == DatabasePath.default_path()
  end
end
