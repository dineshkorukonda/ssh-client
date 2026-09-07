defmodule SSHClient.Terminal.BufferTest do
  use ExUnit.Case, async: true

  alias SSHClient.Terminal.Buffer

  describe "Terminal.Buffer creation and sizing" do
    test "initializes buffer with specified dimensions" do
      buf = Buffer.new(40, 10)
      assert buf.cols == 40
      assert buf.rows == 10
      assert buf.cursor_col == 0
      assert buf.cursor_row == 0
      assert map_size(buf.lines) == 10
    end

    test "resizes buffer dimensions" do
      buf = Buffer.new(40, 10) |> Buffer.feed("Hello world")
      resized = Buffer.resize(buf, 60, 15)
      assert resized.cols == 60
      assert resized.rows == 15
      assert String.contains?(Buffer.to_text(resized), "Hello world")
    end
  end

  describe "Character feeding and cursor movement" do
    test "writes plain text sequentially" do
      buf = Buffer.new(20, 5) |> Buffer.feed("Hello")
      assert buf.cursor_col == 5
      assert buf.cursor_row == 0
      assert Buffer.to_text(buf) == "Hello"
    end

    test "handles carriage return and newline" do
      buf = Buffer.new(20, 5) |> Buffer.feed("First\r\nSecond")
      assert buf.cursor_row == 1
      assert buf.cursor_col == 6
      assert Buffer.to_text(buf) == "First\nSecond"
    end

    test "handles backspace" do
      buf = Buffer.new(20, 5) |> Buffer.feed("abc\bd")
      assert Buffer.to_text(buf) == "abd"
      assert buf.cursor_col == 3
    end

    test "scrolls lines up when reaching bottom of screen and retains scrollback" do
      buf = Buffer.new(20, 3) |> Buffer.feed("Line1\r\nLine2\r\nLine3\r\nLine4")
      assert Buffer.to_screen_text(buf) == "Line2\nLine3\nLine4"
      assert Buffer.to_text(buf) == "Line1\nLine2\nLine3\nLine4"
      assert buf.cursor_row == 2
      assert buf.scrollback_count == 1
    end
  end

  describe "ANSI escape sequence parsing" do
    test "parses SGR bold and color styling" do
      # \e[1;32m is bold green, \e[0m is reset
      buf = Buffer.new(30, 5) |> Buffer.feed("Norm \e[1;32mGreen\e[0m End")
      text = Buffer.to_text(buf)
      assert text == "Norm Green End"

      [first_line | _] = Buffer.to_html_lines(buf)
      assert String.contains?(first_line, "<span")
      assert String.contains?(first_line, "color: #22c55e")
      assert String.contains?(first_line, "font-weight: bold")
    end

    test "parses cursor positioning commands" do
      # Move cursor to row 3, col 5 (\e[3;5H)
      buf = Buffer.new(20, 5) |> Buffer.feed("\e[3;5HHi")
      assert buf.cursor_row == 2
      assert buf.cursor_col == 6
    end

    test "parses clear screen command" do
      buf =
        Buffer.new(20, 5)
        |> Buffer.feed("Text everywhere")
        |> Buffer.feed("\e[2J")

      assert Buffer.to_text(buf) == ""
      assert buf.cursor_col == 0
      assert buf.cursor_row == 0
    end

    test "parses clear line command" do
      buf =
        Buffer.new(20, 5)
        |> Buffer.feed("First Line")
        |> Buffer.feed("\r\e[KSecond")

      assert Buffer.to_text(buf) == "Second"
    end

    test "generates snapshot map for JSON transmission" do
      buf = Buffer.new(20, 5) |> Buffer.feed("Ready")
      snapshot = Buffer.to_snapshot(buf)
      assert snapshot.cols == 20
      assert snapshot.rows == 5
      assert snapshot.cursor.col == 5
      assert snapshot.text == "Ready"
      assert is_list(snapshot.html_lines)
    end
  end
end
