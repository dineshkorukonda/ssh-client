defmodule SSHClient.DatabasePath do
  @moduledoc """
  Resolves the persistent terminal workspace database location.
  """

  @database_filename "terminal_workspaces.db"

  @spec default_path() :: Path.t()
  def default_path do
    Path.join(SSHClient.Config.os_config_dir(), @database_filename)
  end

  @spec resolve(map()) :: Path.t()
  def resolve(environment \\ System.get_env()) do
    case Map.get(environment, "SSH_CLIENT_DATABASE_PATH") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> default_path()
    end
  end
end
