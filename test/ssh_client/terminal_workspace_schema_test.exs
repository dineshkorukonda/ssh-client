defmodule SSHClient.TerminalWorkspaceSchemaTest do
  use ExUnit.Case, async: false

  alias SSHClient.Repo
  alias SSHClient.TerminalWorkspace.LayoutNode
  alias SSHClient.TerminalWorkspace.Preference
  alias SSHClient.TerminalWorkspace.Tab
  alias SSHClient.TerminalWorkspace.Workspace

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "schemas expose stable pane and host identifiers without secrets or runtime sessions" do
    assert :pane_id in LayoutNode.__schema__(:fields)
    assert :host_id in LayoutNode.__schema__(:fields)

    persisted_fields =
      [Workspace, Tab, LayoutNode, Preference]
      |> Enum.flat_map(& &1.__schema__(:fields))

    refute :password in persisted_fields
    refute :credential in persisted_fields
    refute :credentials in persisted_fields
    refute :session_id in persisted_fields
    refute :runtime_session_id in persisted_fields
  end

  test "focused schema changesets accept a complete valid workspace tree" do
    assert Workspace.changeset(struct(Workspace), %{name: "Primary", position: 0}).valid?

    assert Tab.changeset(struct(Tab), %{
             workspace_id: 1,
             stable_id: "tab-primary",
             title: "Terminal",
             position: 0
           }).valid?

    assert LayoutNode.changeset(struct(LayoutNode), %{
             terminal_tab_id: 1,
             node_type: :pane,
             position: 0,
             pane_id: "pane-primary",
             host_id: "host-primary"
           }).valid?

    assert Preference.changeset(struct(Preference), %{
             workspace_id: 1,
             font_family: "Cascadia Mono",
             font_size: 14,
             line_height: 1.25,
             cursor_style: :block,
             cursor_blink: true,
             scrollback: 10_000,
             theme: "dark"
           }).valid?
  end

  test "preference changeset rejects invalid values and accepts boundary values" do
    invalid =
      Preference.changeset(struct(Preference), %{
        workspace_id: 1,
        font_family: "",
        font_size: 7,
        line_height: 3.1,
        cursor_style: :box,
        cursor_blink: true,
        scrollback: -1,
        theme: ""
      })

    refute invalid.valid?

    assert errors_on(invalid) == %{
             cursor_style: ["is invalid"],
             font_family: ["can't be blank"],
             font_size: ["must be greater than or equal to 8"],
             line_height: ["must be less than or equal to 3.0"],
             scrollback: ["must be greater than or equal to 0"],
             theme: ["can't be blank"]
           }

    assert Preference.changeset(struct(Preference), %{
             workspace_id: 1,
             font_family: "monospace",
             font_size: 72,
             line_height: 1.0,
             cursor_style: :bar,
             cursor_blink: false,
             scrollback: 0,
             theme: "dark"
           }).valid?
  end

  test "database rejects an invalid preference from an asynchronous writer" do
    workspace = Repo.insert!(struct(Workspace, name: "Async", position: 200))

    task =
      Task.async(fn ->
        struct(Preference)
        |> Ecto.Changeset.change(%{
          workspace_id: workspace.id,
          font_family: "monospace",
          font_size: 100,
          line_height: 1.2,
          cursor_style: :block,
          cursor_blink: true,
          scrollback: 10_000,
          theme: "dark"
        })
        |> Ecto.Changeset.check_constraint(:font_size,
          name: :terminal_preferences_font_size_valid
        )
        |> Repo.insert()
      end)

    assert {:error, changeset} = Task.await(task)
    assert "is invalid" in errors_on(changeset).font_size
  end

  test "duplicate sibling positions return a layout changeset error" do
    tab = insert_tab(300)

    root =
      Repo.insert!(
        LayoutNode.changeset(struct(LayoutNode), %{
          terminal_tab_id: tab.id,
          node_type: :split,
          position: 0,
          direction: :horizontal,
          ratio: 0.5
        })
      )

    Repo.insert!(
      LayoutNode.changeset(struct(LayoutNode), %{
        terminal_tab_id: tab.id,
        parent_id: root.id,
        node_type: :pane,
        position: 0,
        pane_id: "pane-first",
        host_id: "host-first"
      })
    )

    assert {:error, changeset} =
             Repo.insert(
               LayoutNode.changeset(struct(LayoutNode), %{
                 terminal_tab_id: tab.id,
                 parent_id: root.id,
                 node_type: :pane,
                 position: 0,
                 pane_id: "pane-second",
                 host_id: "host-second"
               })
             )

    assert "has already been taken" in errors_on(changeset).position
  end

  test "a second root returns a layout changeset error" do
    tab = insert_tab(400)

    Repo.insert!(
      LayoutNode.changeset(struct(LayoutNode), %{
        terminal_tab_id: tab.id,
        node_type: :pane,
        position: 0,
        pane_id: "root-first",
        host_id: "host-first"
      })
    )

    assert {:error, changeset} =
             Repo.insert(
               LayoutNode.changeset(struct(LayoutNode), %{
                 terminal_tab_id: tab.id,
                 node_type: :pane,
                 position: 1,
                 pane_id: "root-second",
                 host_id: "host-second"
               })
             )

    assert "has already been taken" in errors_on(changeset).parent_id
  end

  test "position check constraints are mapped symmetrically" do
    assert has_constraint?(
             Workspace.changeset(struct(Workspace), %{name: "Workspace", position: 0}),
             :check,
             "workspaces_position_nonnegative"
           )

    assert has_constraint?(
             Tab.changeset(struct(Tab), %{
               workspace_id: 1,
               stable_id: "tab",
               title: "Tab",
               position: 0
             }),
             :check,
             "terminal_tabs_position_nonnegative"
           )

    assert has_constraint?(
             LayoutNode.changeset(struct(LayoutNode), %{
               terminal_tab_id: 1,
               node_type: :pane,
               position: 0,
               pane_id: "pane",
               host_id: "host"
             }),
             :check,
             "layout_nodes_position_nonnegative"
           )
  end

  defp insert_tab(workspace_position) do
    workspace =
      Repo.insert!(struct(Workspace, name: "Constraints", position: workspace_position))

    Repo.insert!(
      struct(Tab,
        workspace_id: workspace.id,
        stable_id: "tab-#{workspace_position}",
        title: "Terminal",
        position: 0
      )
    )
  end

  defp has_constraint?(changeset, type, name) do
    Enum.any?(changeset.constraints, &(&1.type == type and &1.constraint == name))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        options |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
