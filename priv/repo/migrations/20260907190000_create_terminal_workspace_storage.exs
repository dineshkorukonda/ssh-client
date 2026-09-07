defmodule SSHClient.Repo.Migrations.CreateTerminalWorkspaceStorage do
  use Ecto.Migration

  def change do
    create table(:workspaces) do
      add(:name, :string, null: false)

      add(:position, :integer,
        null: false,
        default: 0,
        check: %{name: "workspaces_position_nonnegative", expr: "position >= 0"}
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:workspaces, [:position]))

    create table(:terminal_tabs) do
      add(:workspace_id, references(:workspaces, on_delete: :delete_all), null: false)
      add(:stable_id, :string, null: false)
      add(:title, :string, null: false)

      add(:position, :integer,
        null: false,
        default: 0,
        check: %{name: "terminal_tabs_position_nonnegative", expr: "position >= 0"}
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:terminal_tabs, [:workspace_id, :stable_id]))
    create(unique_index(:terminal_tabs, [:workspace_id, :position]))

    create table(:layout_nodes) do
      add(:terminal_tab_id, references(:terminal_tabs, on_delete: :delete_all), null: false)
      add(:parent_id, references(:layout_nodes, on_delete: :delete_all))

      add(:node_type, :string,
        null: false,
        check: %{
          name: "layout_nodes_shape_valid",
          expr: """
          (node_type = 'split' AND direction IN ('horizontal', 'vertical')
            AND ratio > 0.0 AND ratio < 1.0 AND pane_id IS NULL AND host_id IS NULL)
          OR
          (node_type = 'pane' AND direction IS NULL AND ratio IS NULL
            AND pane_id IS NOT NULL AND host_id IS NOT NULL)
          """
        }
      )

      add(:position, :integer,
        null: false,
        default: 0,
        check: %{name: "layout_nodes_position_nonnegative", expr: "position >= 0"}
      )

      add(:direction, :string)
      add(:ratio, :float)
      add(:pane_id, :string)
      add(:host_id, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:layout_nodes, [:pane_id], where: "pane_id IS NOT NULL"))
    create(unique_index(:layout_nodes, [:terminal_tab_id, :parent_id, :position]))

    create(
      unique_index(:layout_nodes, [:terminal_tab_id],
        where: "parent_id IS NULL",
        name: :layout_nodes_one_root_per_tab
      )
    )

    create table(:terminal_preferences) do
      add(:workspace_id, references(:workspaces, on_delete: :delete_all), null: false)
      add(:font_family, :string, null: false, default: "monospace")

      add(:font_size, :integer,
        null: false,
        default: 14,
        check: %{
          name: "terminal_preferences_font_size_valid",
          expr: "font_size BETWEEN 8 AND 72"
        }
      )

      add(:line_height, :float,
        null: false,
        default: 1.2,
        check: %{
          name: "terminal_preferences_line_height_valid",
          expr: "line_height BETWEEN 1.0 AND 3.0"
        }
      )

      add(:cursor_style, :string,
        null: false,
        default: "block",
        check: %{
          name: "terminal_preferences_cursor_style_valid",
          expr: "cursor_style IN ('block', 'underline', 'bar')"
        }
      )

      add(:cursor_blink, :boolean, null: false, default: true)

      add(:scrollback, :integer,
        null: false,
        default: 10_000,
        check: %{
          name: "terminal_preferences_scrollback_valid",
          expr: "scrollback BETWEEN 0 AND 1000000"
        }
      )

      add(:theme, :string, null: false, default: "dark")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:terminal_preferences, [:workspace_id]))
  end
end
