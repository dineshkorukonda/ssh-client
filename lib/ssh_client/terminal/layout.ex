defmodule SSHClient.Terminal.Layout do
  @moduledoc """
  Terminal pane layout data structure supporting topologies:
  - `:single`: 1 pane
  - `:split_h`: 2 panes side-by-side (horizontal split)
  - `:split_v`: 2 panes stacked vertically (vertical split)
  - `:grid`: 3 or 4 panes in a 2x2 grid layout
  """

  @max_panes 4

  @type pane_id :: String.t()
  @type topology :: :single | :split_h | :split_v | :grid
  @type direction :: :horizontal | :vertical

  @type t :: %__MODULE__{
          type: topology(),
          panes: [pane_id()],
          active_pane: pane_id() | nil
        }

  defstruct type: :single,
            panes: [],
            active_pane: nil

  @doc """
  Creates a new layout starting with a single active pane.
  """
  def new(session_id) when is_binary(session_id) do
    %__MODULE__{
      type: :single,
      panes: [session_id],
      active_pane: session_id
    }
  end

  @doc """
  Returns the list of pane session IDs in visual order.
  """
  def panes(%__MODULE__{panes: panes}), do: panes

  @doc """
  Returns the currently active pane ID.
  """
  def active_pane(%__MODULE__{active_pane: active_pane}), do: active_pane

  @doc """
  Sets the active pane. If the pane does not exist, the layout is unchanged.
  """
  def set_active(%__MODULE__{panes: panes} = layout, pane_id) when is_binary(pane_id) do
    if pane_id in panes do
      %{layout | active_pane: pane_id}
    else
      layout
    end
  end

  @doc """
  Splits the target pane in the given direction (:horizontal or :vertical)
  by adding `new_session_id`.
  Caps maximum panes at 4.
  """
  def split(%__MODULE__{panes: panes} = layout, target_pane_id, direction, new_session_id)
      when is_binary(new_session_id) and direction in [:horizontal, :vertical] do
    if length(panes) >= @max_panes or new_session_id in panes do
      layout
    else
      new_panes = insert_after(panes, target_pane_id, new_session_id)
      new_type = compute_topology(new_panes, direction)

      %{layout |
        type: new_type,
        panes: new_panes,
        active_pane: new_session_id
      }
    end
  end

  @doc """
  Closes a pane and adjusts topology and active pane.
  """
  def close_pane(%__MODULE__{panes: panes} = layout, pane_id) when is_binary(pane_id) do
    if pane_id in panes do
      new_panes = List.delete(panes, pane_id)

      new_active =
        if layout.active_pane == pane_id do
          pick_fallback_active(panes, pane_id, new_panes)
        else
          layout.active_pane
        end

      new_type =
        case length(new_panes) do
          0 -> :single
          1 -> :single
          2 ->
            if layout.type == :split_v, do: :split_v, else: :split_h
          _ -> :grid
        end

      %{layout |
        type: new_type,
        panes: new_panes,
        active_pane: new_active
      }
    else
      layout
    end
  end

  @doc """
  Swaps the positions of two panes.
  """
  def swap_panes(%__MODULE__{panes: panes} = layout, pane_a, pane_b)
      when is_binary(pane_a) and is_binary(pane_b) do
    if pane_a in panes and pane_b in panes and pane_a != pane_b do
      idx_a = Enum.find_index(panes, &(&1 == pane_a))
      idx_b = Enum.find_index(panes, &(&1 == pane_b))

      new_panes =
        panes
        |> List.replace_at(idx_a, pane_b)
        |> List.replace_at(idx_b, pane_a)

      %{layout | panes: new_panes}
    else
      layout
    end
  end

  @doc """
  Returns the next pane ID in cyclic order after the active pane.
  """
  def next_pane(%__MODULE__{panes: []}), do: nil
  def next_pane(%__MODULE__{panes: [single]}), do: single

  def next_pane(%__MODULE__{panes: panes, active_pane: active}) do
    idx = Enum.find_index(panes, &(&1 == active)) || 0
    next_idx = rem(idx + 1, length(panes))
    Enum.at(panes, next_idx)
  end

  defp insert_after(list, target, new_elem) do
    case Enum.find_index(list, &(&1 == target)) do
      nil -> list ++ [new_elem]
      idx -> List.insert_at(list, idx + 1, new_elem)
    end
  end

  defp compute_topology(panes, direction) do
    case length(panes) do
      1 -> :single
      2 ->
        case direction do
          :horizontal -> :split_h
          :vertical -> :split_v
        end
      _ -> :grid
    end
  end

  defp pick_fallback_active(original_panes, removed_pane, remaining_panes) do
    case remaining_panes do
      [] -> nil
      [single] -> single
      _ ->
        idx = Enum.find_index(original_panes, &(&1 == removed_pane)) || 0
        prev_idx = max(idx - 1, 0)
        Enum.at(remaining_panes, min(prev_idx, length(remaining_panes) - 1))
    end
  end
end
