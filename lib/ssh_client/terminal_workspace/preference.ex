defmodule SSHClient.TerminalWorkspace.Preference do
  use Ecto.Schema
  import Ecto.Changeset

  schema "terminal_preferences" do
    field(:font_family, :string)
    field(:font_size, :integer)
    field(:line_height, :float)
    field(:cursor_style, Ecto.Enum, values: [:block, :underline, :bar])
    field(:cursor_blink, :boolean)
    field(:scrollback, :integer)
    field(:theme, :string)

    belongs_to(:workspace, SSHClient.TerminalWorkspace.Workspace)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(preference, attributes) do
    preference
    |> cast(attributes, [
      :workspace_id,
      :font_family,
      :font_size,
      :line_height,
      :cursor_style,
      :cursor_blink,
      :scrollback,
      :theme
    ])
    |> validate_required([
      :workspace_id,
      :font_family,
      :font_size,
      :line_height,
      :cursor_style,
      :cursor_blink,
      :scrollback,
      :theme
    ])
    |> validate_number(:font_size, greater_than_or_equal_to: 8, less_than_or_equal_to: 72)
    |> validate_number(:line_height,
      greater_than_or_equal_to: 1.0,
      less_than_or_equal_to: 3.0
    )
    |> validate_number(:scrollback,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1_000_000
    )
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:workspace_id)
    |> check_constraint(:font_size, name: :terminal_preferences_font_size_valid)
    |> check_constraint(:line_height, name: :terminal_preferences_line_height_valid)
    |> check_constraint(:cursor_style, name: :terminal_preferences_cursor_style_valid)
    |> check_constraint(:scrollback, name: :terminal_preferences_scrollback_valid)
  end
end
