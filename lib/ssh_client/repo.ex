defmodule SSHClient.Repo do
  use Ecto.Repo,
    otp_app: :ssh_client,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    config
    |> Keyword.fetch!(:database)
    |> Path.dirname()
    |> File.mkdir_p!()

    {:ok, config}
  end
end
