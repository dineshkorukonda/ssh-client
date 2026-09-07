defmodule SSHClient.Terminal.LayoutTest do
  use ExUnit.Case, async: true

  alias SSHClient.Terminal.Layout

  describe "new/1" do
    test "creates initial single-pane layout" do
      layout = Layout.new("sess_1")

      assert layout.type == :single
      assert Layout.active_pane(layout) == "sess_1"
      assert Layout.panes(layout) == ["sess_1"]
    end
  end

  describe "split/4" do
    test "splits single layout horizontally" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")

      assert layout.type == :split_h
      assert Layout.panes(layout) == ["sess_1", "sess_2"]
      assert Layout.active_pane(layout) == "sess_2"
    end

    test "splits single layout vertically" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :vertical, "sess_2")

      assert layout.type == :split_v
      assert Layout.panes(layout) == ["sess_1", "sess_2"]
      assert Layout.active_pane(layout) == "sess_2"
    end

    test "splits two panes into a 3-pane grid" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.split("sess_2", :vertical, "sess_3")

      assert layout.type == :grid
      assert Layout.panes(layout) == ["sess_1", "sess_2", "sess_3"]
      assert Layout.active_pane(layout) == "sess_3"
    end

    test "splits three panes into a 4-pane grid" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.split("sess_2", :vertical, "sess_3")
        |> Layout.split("sess_3", :horizontal, "sess_4")

      assert layout.type == :grid
      assert length(Layout.panes(layout)) == 4
      assert Layout.panes(layout) == ["sess_1", "sess_2", "sess_3", "sess_4"]
      assert Layout.active_pane(layout) == "sess_4"
    end

    test "caps layout at 4 panes" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.split("sess_2", :vertical, "sess_3")
        |> Layout.split("sess_3", :horizontal, "sess_4")
        |> Layout.split("sess_4", :vertical, "sess_5")

      assert length(Layout.panes(layout)) == 4
      refute "sess_5" in Layout.panes(layout)
    end
  end

  describe "close_pane/2" do
    test "closing a pane transitions 2-pane layout back to single" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.close_pane("sess_2")

      assert layout.type == :single
      assert Layout.panes(layout) == ["sess_1"]
      assert Layout.active_pane(layout) == "sess_1"
    end

    test "closing the active pane reassigns active focus to remaining pane" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.close_pane("sess_2")

      assert Layout.active_pane(layout) == "sess_1"

      layout2 =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.set_active("sess_1")
        |> Layout.close_pane("sess_1")

      assert Layout.active_pane(layout2) == "sess_2"
      assert Layout.panes(layout2) == ["sess_2"]
      assert layout2.type == :single
    end

    test "closing a pane in 3-pane grid transitions back to 2-pane split" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.split("sess_2", :vertical, "sess_3")
        |> Layout.close_pane("sess_3")

      assert layout.type == :split_h
      assert Layout.panes(layout) == ["sess_1", "sess_2"]
    end
  end

  describe "active_pane/1 and set_active/2" do
    test "changes active pane when valid" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.set_active("sess_1")

      assert Layout.active_pane(layout) == "sess_1"
    end

    test "ignores unknown pane id when setting active" do
      layout =
        Layout.new("sess_1")
        |> Layout.set_active("nonexistent")

      assert Layout.active_pane(layout) == "sess_1"
    end
  end

  describe "swap_panes/3" do
    test "swaps positions of two panes" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.swap_panes("sess_1", "sess_2")

      assert Layout.panes(layout) == ["sess_2", "sess_1"]
    end

    test "no-op if a pane does not exist" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.swap_panes("sess_1", "missing")

      assert Layout.panes(layout) == ["sess_1", "sess_2"]
    end
  end

  describe "next_pane/1" do
    test "cycles through panes" do
      layout =
        Layout.new("sess_1")
        |> Layout.split("sess_1", :horizontal, "sess_2")
        |> Layout.split("sess_2", :vertical, "sess_3")

      assert Layout.next_pane(layout) == "sess_1"

      layout = Layout.set_active(layout, "sess_1")
      assert Layout.next_pane(layout) == "sess_2"

      layout = Layout.set_active(layout, "sess_2")
      assert Layout.next_pane(layout) == "sess_3"
    end
  end
end
