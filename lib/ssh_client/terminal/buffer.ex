defmodule SSHClient.Terminal.Buffer do
  @moduledoc """
  Terminal screen buffer and ANSI escape sequence processor.
  Maintains screen state, cursor position, text styles, and line scrolling.
  """

  defstruct [
    :cols,
    :rows,
    :cursor_col,
    :cursor_row,
    :lines,
    :style,
    :cursor_visible,
    scrollback: [],
    scrollback_count: 0,
    max_scrollback: 1000
  ]

  @default_style %{
    fg: nil,
    bg: nil,
    bold: false,
    underline: false,
    reverse: false
  }

  @type cell :: %{
          char: String.t(),
          fg: String.t() | nil,
          bg: String.t() | nil,
          bold: boolean(),
          underline: boolean(),
          reverse: boolean()
        }

  @type t :: %__MODULE__{
          cols: pos_integer(),
          rows: pos_integer(),
          cursor_col: non_neg_integer(),
          cursor_row: non_neg_integer(),
          lines: %{non_neg_integer() => [cell()]},
          style: map(),
          cursor_visible: boolean(),
          scrollback: [[cell()]],
          scrollback_count: non_neg_integer(),
          max_scrollback: non_neg_integer()
        }

  @doc """
  Initializes a new blank terminal buffer of specified dimensions and optional scrollback limit.
  """
  def new(cols \\ 80, rows \\ 24, opts \\ []) when cols > 0 and rows > 0 do
    blank_lines =
      for r <- 0..(rows - 1), into: %{} do
        {r, blank_row(cols)}
      end

    max_scrollback =
      if is_list(opts), do: Keyword.get(opts, :max_scrollback, 1000), else: 1000

    %__MODULE__{
      cols: cols,
      rows: rows,
      cursor_col: 0,
      cursor_row: 0,
      lines: blank_lines,
      style: @default_style,
      cursor_visible: true,
      scrollback: [],
      scrollback_count: 0,
      max_scrollback: max_scrollback
    }
  end

  @doc """
  Feeds a binary stream of terminal characters and ANSI sequences into the buffer.
  """
  def feed(%__MODULE__{} = buf, <<>>), do: buf

  def feed(%__MODULE__{} = buf, data) when is_binary(data) do
    parse_stream(data, buf)
  end

  @doc """
  Resizes the buffer dimensions to new cols and rows.
  """
  def resize(%__MODULE__{} = buf, new_cols, new_rows)
      when is_integer(new_cols) and is_integer(new_rows) and new_cols > 0 and new_rows > 0 do
    new_lines =
      for r <- 0..(new_rows - 1), into: %{} do
        existing_row = Map.get(buf.lines, r, [])

        trimmed_or_padded =
          if length(existing_row) >= new_cols do
            Enum.take(existing_row, new_cols)
          else
            existing_row ++ blank_cells(new_cols - length(existing_row))
          end

        {r, trimmed_or_padded}
      end

    cur_col = min(buf.cursor_col, new_cols - 1)
    cur_row = min(buf.cursor_row, new_rows - 1)

    %{
      buf
      | cols: new_cols,
        rows: new_rows,
        cursor_col: max(cur_col, 0),
        cursor_row: max(cur_row, 0),
        lines: new_lines
    }
  end

  @doc """
  Renders the buffer content as plain text lines separated by newlines.
  Includes scrollback history lines before active screen rows.
  """
  def to_text(%__MODULE__{} = buf) do
    scrollback_lines =
      buf.scrollback
      |> Enum.reverse()
      |> Enum.map(fn row_cells ->
        row_cells |> Enum.map(& &1.char) |> Enum.join() |> String.trim_trailing()
      end)

    screen_lines =
      for r <- 0..(buf.rows - 1) do
        row_cells = Map.get(buf.lines, r, [])
        row_cells |> Enum.map(& &1.char) |> Enum.join() |> String.trim_trailing()
      end

    (scrollback_lines ++ screen_lines)
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  @doc """
  Renders only the active visible screen rows as plain text.
  """
  def to_screen_text(%__MODULE__{} = buf) do
    for r <- 0..(buf.rows - 1) do
      row_cells = Map.get(buf.lines, r, [])
      row_cells |> Enum.map(& &1.char) |> Enum.join() |> String.trim_trailing()
    end
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  @doc """
  Renders each line of the buffer into rich text HTML suitable for Qt Quick Text components.
  Includes scrollback history lines before active screen rows.
  """
  def to_html_lines(%__MODULE__{} = buf) do
    scrollback_html =
      buf.scrollback
      |> Enum.reverse()
      |> Enum.map(&render_html_row/1)

    screen_html =
      for r <- 0..(buf.rows - 1) do
        row_cells = Map.get(buf.lines, r, [])
        render_html_row(row_cells)
      end

    scrollback_html ++ screen_html
  end

  @doc """
  Serializes the buffer state to a map for JSON transport.
  """
  def to_snapshot(%__MODULE__{} = buf) do
    %{
      cols: buf.cols,
      rows: buf.rows,
      cursor: %{col: buf.cursor_col, row: buf.cursor_row, visible: buf.cursor_visible},
      text: to_text(buf),
      html_lines: to_html_lines(buf),
      scrollback_count: buf.scrollback_count
    }
  end

  # Stream Parser Implementation

  defp parse_stream(<<>>, buf), do: buf

  # Escape sequence start: ESC [ (CSI)
  defp parse_stream(<<"\e[", rest::binary>>, buf) do
    case parse_csi(rest) do
      {:ok, csi_cmd, remaining} ->
        new_buf = handle_csi(csi_cmd, buf)
        parse_stream(remaining, new_buf)

      :error ->
        parse_stream(rest, buf)
    end
  end

  # Operating System Command (OSC): ESC ] ... BEL or ESC \
  defp parse_stream(<<"\e]", rest::binary>>, buf) do
    remaining = skip_osc(rest)
    parse_stream(remaining, buf)
  end

  # Lone ESC or unhandled escape: ESC ( or ESC ) charset selection
  defp parse_stream(<<"\e", _char, rest::binary>>, buf) do
    parse_stream(rest, buf)
  end

  # Carriage Return (\r)
  defp parse_stream(<<"\r", rest::binary>>, buf) do
    parse_stream(rest, %{buf | cursor_col: 0})
  end

  # Newline (\n)
  defp parse_stream(<<"\n", rest::binary>>, buf) do
    parse_stream(rest, linefeed(buf))
  end

  # Backspace (\b or 0x08)
  defp parse_stream(<<"\b", rest::binary>>, buf) do
    new_col = max(buf.cursor_col - 1, 0)
    parse_stream(rest, %{buf | cursor_col: new_col})
  end

  # Tab (\t)
  defp parse_stream(<<"\t", rest::binary>>, buf) do
    next_tab = div(buf.cursor_col + 8, 8) * 8
    new_col = min(next_tab, buf.cols - 1)
    parse_stream(rest, %{buf | cursor_col: new_col})
  end

  # Bell (\a or 0x07)
  defp parse_stream(<<7, rest::binary>>, buf) do
    parse_stream(rest, buf)
  end

  # Standard UTF-8 character
  defp parse_stream(<<char::utf8, rest::binary>>, buf) do
    new_buf = put_char(buf, <<char::utf8>>)
    parse_stream(rest, new_buf)
  end

  # Fallback byte
  defp parse_stream(<<_byte, rest::binary>>, buf) do
    parse_stream(rest, buf)
  end

  # CSI Parsing and Dispatching

  defp parse_csi(bin) do
    Regex.run(~r/^(\??[0-9;]*)([A-Za-z])/, bin, return: :index)
    |> case do
      [{0, len}, {param_start, param_len}, {final_start, _}] ->
        params = binary_part(bin, param_start, param_len)
        final_char = binary_part(bin, final_start, 1)
        remaining = binary_part(bin, len, byte_size(bin) - len)
        {:ok, {params, final_char}, remaining}

      _ ->
        :error
    end
  end

  defp skip_osc(bin) do
    case :binary.match(bin, [<<7>>, <<"\e\\">>]) do
      {pos, len} -> binary_part(bin, pos + len, byte_size(bin) - (pos + len))
      :nomatch -> <<>>
    end
  end

  defp handle_csi({params, "m"}, buf) do
    codes = parse_int_params(params, [0])
    new_style = Enum.reduce(codes, buf.style, &apply_sgr/2)
    %{buf | style: new_style}
  end

  defp handle_csi({params, "H"}, buf), do: set_cursor_pos(buf, params)
  defp handle_csi({params, "f"}, buf), do: set_cursor_pos(buf, params)

  defp handle_csi({params, "A"}, buf) do
    [n] = parse_int_params(params, [1])
    %{buf | cursor_row: max(buf.cursor_row - n, 0)}
  end

  defp handle_csi({params, "B"}, buf) do
    [n] = parse_int_params(params, [1])
    %{buf | cursor_row: min(buf.cursor_row + n, buf.rows - 1)}
  end

  defp handle_csi({params, "C"}, buf) do
    [n] = parse_int_params(params, [1])
    %{buf | cursor_col: min(buf.cursor_col + n, buf.cols - 1)}
  end

  defp handle_csi({params, "D"}, buf) do
    [n] = parse_int_params(params, [1])
    %{buf | cursor_col: max(buf.cursor_col - n, 0)}
  end

  defp handle_csi({params, "J"}, buf) do
    mode = List.first(parse_int_params(params, [0]))
    clear_screen(buf, mode)
  end

  defp handle_csi({params, "K"}, buf) do
    mode = List.first(parse_int_params(params, [0]))
    clear_line(buf, mode)
  end

  defp handle_csi({"?25h", _}, buf), do: %{buf | cursor_visible: true}
  defp handle_csi({"?25l", _}, buf), do: %{buf | cursor_visible: false}

  defp handle_csi(_other, buf), do: buf

  # Cursor & Cell Operations

  defp put_char(buf, char) do
    row = buf.cursor_row
    col = buf.cursor_col

    cell = %{
      char: char,
      fg: buf.style.fg,
      bg: buf.style.bg,
      bold: buf.style.bold,
      underline: buf.style.underline,
      reverse: buf.style.reverse
    }

    current_row = Map.get(buf.lines, row, blank_row(buf.cols))
    updated_row = List.replace_at(current_row, col, cell)
    new_lines = Map.put(buf.lines, row, updated_row)

    new_col = col + 1

    if new_col >= buf.cols do
      %{buf | lines: new_lines, cursor_col: 0} |> linefeed()
    else
      %{buf | lines: new_lines, cursor_col: new_col}
    end
  end

  defp linefeed(buf) do
    if buf.cursor_row + 1 >= buf.rows do
      scroll_up(buf)
    else
      %{buf | cursor_row: buf.cursor_row + 1}
    end
  end

  defp scroll_up(buf) do
    # Capture top line being scrolled off screen
    top_line = Map.get(buf.lines, 0, blank_row(buf.cols))

    # Push top_line to scrollback list [top_line | scrollback]
    {new_scrollback, new_count} =
      if buf.max_scrollback > 0 do
        sb = [top_line | buf.scrollback]
        cnt = buf.scrollback_count + 1

        if cnt > buf.max_scrollback do
          {Enum.take(sb, buf.max_scrollback), buf.max_scrollback}
        else
          {sb, cnt}
        end
      else
        {[], 0}
      end

    # Shift rows up by 1 and append blank bottom row
    shifted =
      for r <- 0..(buf.rows - 2), into: %{} do
        {r, Map.get(buf.lines, r + 1, blank_row(buf.cols))}
      end

    new_lines = Map.put(shifted, buf.rows - 1, blank_row(buf.cols))

    %{
      buf
      | lines: new_lines,
        cursor_row: buf.rows - 1,
        scrollback: new_scrollback,
        scrollback_count: new_count
    }
  end

  defp set_cursor_pos(buf, params) do
    parts = parse_int_params(params, [1, 1])
    r = max(Enum.at(parts, 0, 1) - 1, 0)
    c = max(Enum.at(parts, 1, 1) - 1, 0)
    %{buf | cursor_row: min(r, buf.rows - 1), cursor_col: min(c, buf.cols - 1)}
  end

  defp clear_screen(buf, 2) do
    blank_lines =
      for r <- 0..(buf.rows - 1), into: %{} do
        {r, blank_row(buf.cols)}
      end

    %{buf | lines: blank_lines, cursor_col: 0, cursor_row: 0}
  end

  defp clear_screen(buf, _), do: clear_screen(buf, 2)

  defp clear_line(buf, 0) do
    # Clear cursor to end of line
    row = Map.get(buf.lines, buf.cursor_row, blank_row(buf.cols))

    updated =
      row
      |> Enum.with_index()
      |> Enum.map(fn {cell, idx} ->
        if idx >= buf.cursor_col, do: blank_cell(), else: cell
      end)

    %{buf | lines: Map.put(buf.lines, buf.cursor_row, updated)}
  end

  defp clear_line(buf, 2) do
    # Clear entire line
    %{buf | lines: Map.put(buf.lines, buf.cursor_row, blank_row(buf.cols))}
  end

  defp clear_line(buf, _), do: clear_line(buf, 2)

  # Style / SGR Parsing

  defp apply_sgr(0, _style), do: @default_style
  defp apply_sgr(1, style), do: %{style | bold: true}
  defp apply_sgr(4, style), do: %{style | underline: true}
  defp apply_sgr(7, style), do: %{style | reverse: true}
  defp apply_sgr(22, style), do: %{style | bold: false}
  defp apply_sgr(24, style), do: %{style | underline: false}
  defp apply_sgr(27, style), do: %{style | reverse: false}

  # Standard ANSI 8 colors (fg: 30-37, bg: 40-47)
  defp apply_sgr(code, style) when code in 30..37, do: %{style | fg: ansi_color(code - 30)}
  defp apply_sgr(39, style), do: %{style | fg: nil}
  defp apply_sgr(code, style) when code in 40..47, do: %{style | bg: ansi_color(code - 40)}
  defp apply_sgr(49, style), do: %{style | bg: nil}

  # Bright colors (fg: 90-97, bg: 100-107)
  defp apply_sgr(code, style) when code in 90..97,
    do: %{style | fg: ansi_bright_color(code - 90)}

  defp apply_sgr(code, style) when code in 100..107,
    do: %{style | bg: ansi_bright_color(code - 100)}

  defp apply_sgr(_other, style), do: style

  defp ansi_color(0), do: "#1f2937"
  defp ansi_color(1), do: "#ef4444"
  defp ansi_color(2), do: "#22c55e"
  defp ansi_color(3), do: "#eab308"
  defp ansi_color(4), do: "#3b82f6"
  defp ansi_color(5), do: "#a855f7"
  defp ansi_color(6), do: "#06b6d4"
  defp ansi_color(7), do: "#e5e7eb"

  defp ansi_bright_color(0), do: "#4b5563"
  defp ansi_bright_color(1), do: "#f87171"
  defp ansi_bright_color(2), do: "#4ade80"
  defp ansi_bright_color(3), do: "#fde047"
  defp ansi_bright_color(4), do: "#60a5fa"
  defp ansi_bright_color(5), do: "#c084fc"
  defp ansi_bright_color(6), do: "#22d3ee"
  defp ansi_bright_color(7), do: "#ffffff"

  defp parse_int_params("", default), do: default

  defp parse_int_params(param_str, default) do
    case String.split(param_str, ";", trim: true) do
      [] ->
        default

      list ->
        Enum.map(list, fn s ->
          case Integer.parse(s) do
            {val, _} -> val
            :error -> 0
          end
        end)
    end
  end

  defp blank_cell do
    %{
      char: " ",
      fg: nil,
      bg: nil,
      bold: false,
      underline: false,
      reverse: false
    }
  end

  defp blank_cells(n) when n <= 0, do: []
  defp blank_cells(n), do: for(_ <- 1..n, do: blank_cell())

  defp blank_row(cols) do
    for _ <- 0..(cols - 1), do: blank_cell()
  end

  defp render_html_row(cells) do
    cells
    |> Enum.chunk_by(fn c -> {c.fg, c.bg, c.bold, c.underline} end)
    |> Enum.map(fn chunk ->
      first = hd(chunk)
      chars = Enum.map(chunk, & &1.char) |> Enum.join() |> html_escape()
      format_span(chars, first)
    end)
    |> Enum.join()
  end

  defp format_span(text, %{fg: nil, bg: nil, bold: false, underline: false}) do
    text
  end

  defp format_span(text, cell) do
    styles = []
    styles = if cell.fg, do: ["color: #{cell.fg}" | styles], else: styles
    styles = if cell.bg, do: ["background-color: #{cell.bg}" | styles], else: styles
    styles = if cell.bold, do: ["font-weight: bold" | styles], else: styles
    styles = if cell.underline, do: ["text-decoration: underline" | styles], else: styles

    style_attr = Enum.join(styles, "; ")
    "<span style=\"#{style_attr}\">#{text}</span>"
  end

  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
