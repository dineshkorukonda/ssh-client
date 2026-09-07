defmodule SSHClient.TerminalWorkspace.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  schema "workspaces" do
    field(:name, :string)
    field(:position, :integer)

    has_many(:terminal_tabs, SSHClient.TerminalWorkspace.Tab)
    has_one(:terminal_preference, SSHClient.TerminalWorkspace.Preference)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(workspace, attributes) do
    workspace
    |> cast(attributes, [:name, :position])
    |> validate_required([:name, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint(:position)
    |> check_constraint(:position, name: :workspaces_position_nonnegative)
  end
end
