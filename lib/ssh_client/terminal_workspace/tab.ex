defmodule SSHClient.TerminalWorkspace.Tab do
  use Ecto.Schema
  import Ecto.Changeset

  schema "terminal_tabs" do
    field(:stable_id, :string)
    field(:title, :string)
    field(:position, :integer)

    belongs_to(:workspace, SSHClient.TerminalWorkspace.Workspace)
    has_many(:layout_nodes, SSHClient.TerminalWorkspace.LayoutNode, foreign_key: :terminal_tab_id)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(tab, attributes) do
    tab
    |> cast(attributes, [:workspace_id, :stable_id, :title, :position])
    |> validate_required([:workspace_id, :stable_id, :title, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :stable_id])
    |> unique_constraint([:workspace_id, :position])
    |> check_constraint(:position, name: :terminal_tabs_position_nonnegative)
  end
end
