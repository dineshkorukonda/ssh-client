defmodule SSHClient.DatabasePathTest do
  use ExUnit.Case, async: false

  alias SSHClient.DatabasePath
  alias SSHClient.Repo

  test "default path uses the OS-specific application config directory" do
    assert DatabasePath.default_path() ==
             Path.join(SSHClient.Config.os_config_dir(), "terminal_workspaces.db")
  end

  test "environment path is expanded for portable installations" do
    path = Path.join([".", "tmp", "portable-workspaces.db"])

    assert DatabasePath.resolve(%{"SSH_CLIENT_DATABASE_PATH" => path}) == Path.expand(path)
  end

  test "test configuration uses an isolated temporary database" do
    configured_path = Application.fetch_env!(:ssh_client, Repo)[:database]

    assert Path.expand(Path.dirname(configured_path)) == Path.expand(System.tmp_dir!())
    assert Path.basename(configured_path) =~ ~r/^ssh_client_test_.+\.db$/
    refute configured_path == DatabasePath.default_path()
  end

  test "repo resolves the database path from the runtime environment" do
    database =
      Path.join(System.tmp_dir!(), "runtime-path-#{System.unique_integer([:positive])}.db")

    previous = System.get_env("SSH_CLIENT_DATABASE_PATH")
    System.put_env("SSH_CLIENT_DATABASE_PATH", database)

    on_exit(fn ->
      if previous do
        System.put_env("SSH_CLIENT_DATABASE_PATH", previous)
      else
        System.delete_env("SSH_CLIENT_DATABASE_PATH")
      end
    end)

    assert {:ok, config} = Repo.init(:supervisor, pool_size: 1)
    assert config[:database] == Path.expand(database)
    assert config[:pool_size] == 1
  end

  test "repo preserves an explicitly configured test database" do
    repo_config = Application.fetch_env!(:ssh_client, Repo)
    database = repo_config[:database]

    assert repo_config[:pool_size] == 1
    assert {:ok, config} = Repo.init(:supervisor, repo_config)
    assert config[:database] == database
  end
end
