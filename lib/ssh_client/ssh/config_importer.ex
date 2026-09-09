defmodule SSHClient.SSH.ConfigImporter do
  @moduledoc """
  Parses OpenSSH `~/.ssh/config` files and imports host definitions as
  `%SSHClient.Host{}` structs, deduplicating against already existing hosts.
  """

  alias SSHClient.Host

  @doc """
  Default path to OpenSSH config file across platforms:
  - Linux / macOS: ~/.ssh/config
  - Windows: %USERPROFILE%/.ssh/config
  """
  def default_ssh_config_path do
    home = System.user_home() || "~"
    Path.join([home, ".ssh", "config"])
  end

  @doc """
  Reads and parses an OpenSSH config file from the specified path or default.
  """
  def import_file(path \\ default_ssh_config_path()) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, parse_string(content)}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "failed to read ssh config '#{path}': #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Parses string content containing OpenSSH config syntax into a list of %Host{} structs.
  Ignores wildcard blocks (e.g. `Host *`).
  """
  def parse_string(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
    |> chunk_hosts([])
    |> Enum.flat_map(&build_host_structs/1)
  end

  @doc """
  Deduplicates a list of newly imported hosts against an existing list of hosts.
  Matches on either ID, host name, or (user, address, port) tuple.
  """
  def deduplicate(imported_hosts, existing_hosts) do
    existing_ids = MapSet.new(Enum.map(existing_hosts, &get_host_prop(&1, :id)))
    existing_names = MapSet.new(Enum.map(existing_hosts, &get_host_prop(&1, :name)))

    existing_endpoints =
      MapSet.new(
        Enum.map(existing_hosts, fn h ->
          {get_host_prop(h, :user), get_host_prop(h, :address), get_host_prop(h, :port)}
        end)
      )

    Enum.reject(imported_hosts, fn imp ->
      endpoint = {imp.user, imp.address, imp.port}

      MapSet.member?(existing_ids, imp.id) or
        MapSet.member?(existing_names, imp.name) or
        MapSet.member?(existing_endpoints, endpoint)
    end)
  end

  defp get_host_prop(%Host{} = h, key), do: Map.get(h, key)
  defp get_host_prop(m, key) when is_map(m), do: Map.get(m, key) || Map.get(m, to_string(key))

  defp chunk_hosts([], acc), do: Enum.reverse(acc)

  defp chunk_hosts([line | rest], acc) do
    if String.match?(line, ~r/^(?i:host)\s+/) do
      {block_lines, remaining} =
        Enum.split_while(rest, fn l -> not String.match?(l, ~r/^(?i:host)\s+/) end)

      chunk_hosts(remaining, [[line | block_lines] | acc])
    else
      chunk_hosts(rest, acc)
    end
  end

  defp build_host_structs([header | lines]) do
    aliases =
      header
      |> String.replace(~r/^(?i:host)\s+/, "")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&String.contains?(&1, "*"))

    if aliases == [] do
      []
    else
      params = parse_lines(lines, %{})

      Enum.map(aliases, fn host_alias ->
        address = Map.get(params, "hostname", host_alias)

        user =
          Map.get(params, "user", System.get_env("USER") || System.get_env("USERNAME") || "root")

        port = Map.get(params, "port", 22)
        identity_file = Map.get(params, "identityfile")
        jump_host = Map.get(params, "proxyjump")

        %Host{
          id: host_alias,
          name: host_alias,
          address: address,
          user: user,
          port: port,
          identity_file: identity_file,
          jump_host: jump_host,
          auth_method: if(identity_file, do: :key, else: :key),
          auth_order: [:key, :password, :keyboard_interactive]
        }
      end)
    end
  end

  defp parse_lines([], acc), do: acc

  defp parse_lines([line | rest], acc) do
    case String.split(line, ~r/\s+|=/, parts: 2) do
      [key, val] ->
        normalized_key = String.downcase(String.trim(key))
        cleaned_val = String.trim(val)

        parsed_val =
          case normalized_key do
            "port" ->
              case Integer.parse(cleaned_val) do
                {p, ""} -> p
                _ -> 22
              end

            "identityfile" ->
              Path.expand(cleaned_val)

            _ ->
              cleaned_val
          end

        parse_lines(rest, Map.put_new(acc, normalized_key, parsed_val))

      _ ->
        parse_lines(rest, acc)
    end
  end
end
