defmodule SSHClient.Config.Server do
  @moduledoc """
  Represents a remote server target for monitoring and management.
  """

  alias SSHClient.Config.Check

  @enforce_keys [:id, :host]
  defstruct [
    :id,
    :name,
    :host,
    :user,
    :proxy_jump,
    :identity_file,
    users: [],
    default_auth_method: :key,
    auth_order: [:key, :password, :keyboard_interactive],
    port: 22,
    checks: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          host: String.t(),
          user: String.t() | nil,
          users: list(String.t()),
          default_auth_method: :key | :password,
          port: pos_integer(),
          proxy_jump: String.t() | nil,
          identity_file: String.t() | nil,
          auth_order: list(atom()),
          checks: list(Check.t())
        }

  @doc """
  Builds and validates a Server struct from raw configuration data.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(attrs) when is_map(attrs) do
    with {:ok, host} <- fetch_host(attrs),
         {:ok, port} <- parse_port(attrs),
         {:ok, checks} <- parse_checks(attrs) do
      id = Map.get(attrs, "id") || Map.get(attrs, :id) || host
      name = Map.get(attrs, "name") || Map.get(attrs, :name) || id
      raw_user = Map.get(attrs, "user") || Map.get(attrs, :user)
      raw_users = Map.get(attrs, "users") || Map.get(attrs, :users)

      users = parse_users(raw_users, raw_user)
      user = if raw_user && to_string(raw_user) != "", do: to_string(raw_user), else: List.first(users)

      proxy_jump =
        Map.get(attrs, "ProxyJump") || Map.get(attrs, "proxy_jump") || Map.get(attrs, :proxy_jump) || Map.get(attrs, "proxyjump")

      identity_file =
        Map.get(attrs, "identity_file") || Map.get(attrs, :identity_file) ||
          Map.get(attrs, "IdentityFile") || Map.get(attrs, "identityfile")

      auth_order = parse_auth_order(attrs)
      default_auth_method = parse_default_auth_method(attrs)

      server = %__MODULE__{
        id: to_string(id),
        name: to_string(name),
        host: to_string(host),
        user: user && to_string(user),
        users: users,
        default_auth_method: default_auth_method,
        port: port,
        proxy_jump: proxy_jump && to_string(proxy_jump),
        identity_file: identity_file && to_string(identity_file),
        auth_order: auth_order,
        checks: checks
      }

      {:ok, server}
    end
  end

  def from_map(_invalid) do
    {:error, "server entry must be a map"}
  end

  defp fetch_host(attrs) when is_map(attrs) do
    host = Map.get(attrs, "host") || Map.get(attrs, :host)
    cond do
      is_binary(host) and byte_size(String.trim(host)) > 0 ->
        {:ok, String.trim(host)}

      is_binary(host) ->
        {:error, "server host must be a non-empty string"}

      true ->
        {:error, "missing required field 'host' in server configuration"}
    end
  end

  defp parse_port(attrs) when is_map(attrs) do
    port = Map.get(attrs, "port") || Map.get(attrs, :port)
    cond do
      is_nil(port) ->
        {:ok, 22}

      is_integer(port) and port in 1..65535 ->
        {:ok, port}

      is_binary(port) ->
        case Integer.parse(port) do
          {int, ""} when int in 1..65535 -> {:ok, int}
          _ -> {:error, "invalid port number: #{port}"}
        end

      true ->
        {:error, "invalid port number: #{inspect(port)}"}
    end
  end

  defp parse_checks(attrs) when is_map(attrs) do
    checks = Map.get(attrs, "checks") || Map.get(attrs, :checks)
    cond do
      is_nil(checks) ->
        {:ok, []}

      is_list(checks) ->
        Enum.reduce_while(checks, {:ok, []}, fn check_map, {:ok, acc} ->
          case Check.from_map(check_map) do
            {:ok, check} -> {:cont, {:ok, [check | acc]}}
            {:error, reason} -> {:halt, {:error, "invalid check in server: #{reason}"}}
          end
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          error -> error
        end

      true ->
        {:error, "'checks' must be a list"}
    end
  end

  defp parse_auth_order(attrs) do
    raw_order =
      Map.get(attrs, "auth_order") || Map.get(attrs, :auth_order) ||
        Map.get(attrs, "auth_methods") || Map.get(attrs, :auth_methods)

    case raw_order do
      list when is_list(list) ->
        Enum.map(list, fn
          a when is_atom(a) -> a
          s when is_binary(s) -> String.to_atom(s)
          other -> other
        end)

      bin when is_binary(bin) ->
        bin
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.to_atom/1)

      _ ->
        [:key, :password, :keyboard_interactive]
    end
  end

  defp parse_users(users, default_user) when is_list(users) do
    parsed =
      users
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      default_user && to_string(default_user) != "" ->
        d_user = String.trim(to_string(default_user))
        if d_user in parsed, do: parsed, else: [d_user | parsed]

      parsed != [] ->
        parsed

      true ->
        []
    end
  end

  defp parse_users(users_str, default_user) when is_binary(users_str) do
    parsed =
      users_str
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parse_users(parsed, default_user)
  end

  defp parse_users(nil, default_user) do
    if default_user && to_string(default_user) != "" do
      [String.trim(to_string(default_user))]
    else
      []
    end
  end

  defp parse_users(_other, default_user), do: parse_users(nil, default_user)

  defp parse_default_auth_method(attrs) do
    val =
      Map.get(attrs, "default_auth_method") ||
        Map.get(attrs, :default_auth_method) ||
        Map.get(attrs, "auth_method") ||
        Map.get(attrs, :auth_method)

    case val do
      :password -> :password
      "password" -> :password
      _ -> :key
    end
  end
end
