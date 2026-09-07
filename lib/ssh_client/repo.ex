defmodule SSHClient.Repo do
  use Ecto.Repo,
    otp_app: :ssh_client,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    database = Keyword.get_lazy(config, :database, &SSHClient.DatabasePath.resolve/0)

    database
    |> Path.dirname()
    |> File.mkdir_p!()

    {:ok, Keyword.put(config, :database, database)}
  end
end
