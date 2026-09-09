defmodule SSHClient.Workspace do
  @moduledoc """
  Named groups of hosts. Opening a workspace restores its saved host list.
  """

  alias SSHClient.Store

  def create(name, server_ids) when is_binary(name) and is_list(server_ids) do
    id = slug(name) <> "-" <> Integer.to_string(System.unique_integer([:positive]))

    record = %{
      "id" => id,
      "name" => String.trim(name),
      "server_ids" => Enum.map(server_ids, &to_string/1),
      "created_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    case Store.put(:workspaces, id, record) do
      :ok -> {:ok, record}
      other -> other
    end
  end

  def list, do: Store.list(:workspaces)

  def get(id), do: Store.get(:workspaces, id)

  def delete(id), do: Store.delete(:workspaces, id)

  def add_host(id, server_id) do
    case get(id) do
      nil ->
        {:error, :not_found}

      ws ->
        ids = Enum.uniq((ws["server_ids"] || []) ++ [to_string(server_id)])
        Store.put(:workspaces, id, Map.put(ws, "server_ids", ids))
    end
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "workspace"
      other -> other
    end
  end
end
