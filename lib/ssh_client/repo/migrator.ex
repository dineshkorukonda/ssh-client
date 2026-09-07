defmodule SSHClient.Repo.Migrator do
  @moduledoc false

  alias SSHClient.Repo

  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary
    }
  end

  def start_link(_options \\ []) do
    {:ok, _migrated_versions, _started_apps} =
      Ecto.Migrator.with_repo(
        Repo,
        &Ecto.Migrator.run(&1, migrations_path(), :up, all: true),
        pool_size: 2,
        mode: :temporary
      )

    :ignore
  end

  defp migrations_path do
    Application.app_dir(:ssh_client, "priv/repo/migrations")
  end
end
