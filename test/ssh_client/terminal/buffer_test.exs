defmodule SSHClient.Terminal.BufferScrollbackTest do
  use ExUnit.Case, async: true

  alias SSHClient.Terminal.Buffer

  describe "Scrollback RingBuffer capacity and circular eviction" do
    test "initializes with default max_scrollback: 1000" do
      buf = Buffer.new(80, 24)
      assert buf.max_scrollback == 1000
      assert buf.scrollback == []
      assert buf.scrollback_count == 0
    end

    test "supports custom max_scrollback option" do
      buf = Buffer.new(40, 5, max_scrollback: 5)
      assert buf.max_scrollback == 5
      assert buf.scrollback_count == 0
    end

    test "retains lines scrolled off top into scrollback" do
      # 3 rows screen, max_scrollback: 10
      buf = Buffer.new(20, 3, max_scrollback: 10)

      # Write lines: Line 1, 2, 3 fills screen. Line 4 pushes Line 1 to scrollback.
      # Line 5 pushes Line 2 to scrollback.
      buf = Buffer.feed(buf, "Line 1\r\nLine 2\r\nLine 3\r\nLine 4\r\nLine 5")

      assert Buffer.to_screen_text(buf) == "Line 3\nLine 4\nLine 5"
      assert buf.scrollback_count == 2

      # to_text returns full history (scrollback + screen)
      full_text = Buffer.to_text(buf)
      assert full_text == "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"

      # Snapshot includes scrollback_count and full history
      snapshot = Buffer.to_snapshot(buf)
      assert snapshot.scrollback_count == 2
      assert snapshot.text == full_text
      assert length(snapshot.html_lines) == 5
    end

    test "enforces circular eviction when scrollback limit is reached" do
      # 2 rows screen, max_scrollback: 3
      buf = Buffer.new(20, 2, max_scrollback: 3)

      # 6 lines total -> 4 lines scroll off top
      # With max_scrollback: 3, the oldest line (Line 1) must be evicted!
      buf = Buffer.feed(buf, "L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6")

      assert buf.scrollback_count == 3
      assert Buffer.to_screen_text(buf) == "L5\nL6"

      # Full text should retain L2, L3, L4 (in scrollback) and L5, L6 (on screen)
      # L1 must have been circularly evicted
      full_text = Buffer.to_text(buf)
      assert full_text == "L2\nL3\nL4\nL5\nL6"
      refute String.contains?(full_text, "L1")
    end

    test "handles large volume without memory explosion or unbounded growth" do
      buf = Buffer.new(40, 5, max_scrollback: 100)

      # Feed 500 lines
      input =
        1..500
        |> Enum.map(fn n -> "Data row #{n}\r\n" end)
        |> Enum.join()

      buf = Buffer.feed(buf, input)

      assert buf.scrollback_count == 100
      snapshot = Buffer.to_snapshot(buf)
      assert snapshot.scrollback_count == 100
      # html_lines returns exact total lines (100 scrollback + 5 screen = 105)
      assert length(snapshot.html_lines) == 105
      # Most recent lines should be present
      assert String.contains?(snapshot.text, "Data row 500")
      # Very old lines should be evicted
      refute String.contains?(snapshot.text, "Data row 1\n")
    end
  end
end
