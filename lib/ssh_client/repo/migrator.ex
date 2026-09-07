defmodule SSHClient.Repo.Migrator do
  @moduledoc false

  use GenServer

  alias SSHClient.Repo

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    Ecto.Migrator.run(Repo, migrations_path(), :up, all: true)
    {:ok, %{}}
  end

  defp migrations_path do
    Application.app_dir(:ssh_client, "priv/repo/migrations")
  end
end
