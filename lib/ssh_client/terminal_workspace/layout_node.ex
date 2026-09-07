defmodule SSHClient.TerminalWorkspace.LayoutNode do
  use Ecto.Schema
  import Ecto.Changeset

  schema "layout_nodes" do
    field(:node_type, Ecto.Enum, values: [:pane, :split])
    field(:position, :integer)
    field(:direction, Ecto.Enum, values: [:horizontal, :vertical])
    field(:ratio, :float)
    field(:pane_id, :string)
    field(:host_id, :string)

    belongs_to(:terminal_tab, SSHClient.TerminalWorkspace.Tab)
    belongs_to(:parent, __MODULE__)
    has_many(:children, __MODULE__, foreign_key: :parent_id)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(layout_node, attributes) do
    layout_node
    |> cast(attributes, [
      :terminal_tab_id,
      :parent_id,
      :node_type,
      :position,
      :direction,
      :ratio,
      :pane_id,
      :host_id
    ])
    |> validate_required([:terminal_tab_id, :node_type, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_shape()
    |> foreign_key_constraint(:terminal_tab_id)
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint(:pane_id)
    |> check_constraint(:node_type, name: :layout_nodes_shape_valid)
  end

  defp validate_shape(changeset) do
    case get_field(changeset, :node_type) do
      :pane ->
        changeset
        |> validate_required([:pane_id, :host_id])
        |> require_absent([:direction, :ratio])

      :split ->
        changeset
        |> validate_required([:direction, :ratio])
        |> validate_number(:ratio, greater_than: 0.0, less_than: 1.0)
        |> require_absent([:pane_id, :host_id])

      _ ->
        changeset
    end
  end

  defp require_absent(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, result ->
      if is_nil(get_field(result, field)) do
        result
      else
        add_error(result, field, "must be blank")
      end
    end)
  end
end
