defmodule SSHClient.Host do
  @moduledoc """
  Data model representing an SSH host target.
  """

  @enforce_keys [:id, :name, :address, :port, :user]
  defstruct [
    :id,
    :name,
    :address,
    :port,
    :user,
    users: [],
    auth_method: :key,
    default_auth_method: :key,
    identity_file: nil,
    jump_host: nil,
    group: nil,
    auth_order: [:key, :password, :keyboard_interactive],
    connect_timeout: 10_000,
    poll_interval: 5_000,
    last_connected_at: nil
  ]

  @type auth_method :: :key | :password | :agent | :keyboard_interactive

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          address: String.t(),
          port: pos_integer(),
          user: String.t(),
          users: list(String.t()),
          auth_method: auth_method(),
          default_auth_method: :key | :password,
          identity_file: Path.t() | nil,
          jump_host: String.t() | nil,
          group: String.t() | nil,
          auth_order: list(atom()),
          connect_timeout: pos_integer(),
          poll_interval: pos_integer(),
          last_connected_at: DateTime.t() | nil
        }

  @doc """
  Parses a quick-add SSH connection string into an %SSHClient.Host{} struct.
  Supports formats:
  - "user@host:port"
  - "user@host"
  - "host:port"
  - "host"
  - "ssh user@host -p port" (optional command-style wrapper)

  Accepts optional default overrides (e.g. `[name: "My Server", group: "Production"]`).
  """
  @spec parse_quick_add(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse_quick_add(input, opts \\ [])

  def parse_quick_add(input, opts) when is_binary(input) do
    cleaned =
      input
      |> String.trim()
      |> String.replace_prefix("ssh ", "")
      |> String.trim()

    cond do
      cleaned == "" ->
        {:error, "Input string cannot be empty"}

      true ->
        do_parse_quick_add(cleaned, opts)
    end
  end

  def parse_quick_add(_, _opts), do: {:error, "Invalid input, string expected"}

  defp do_parse_quick_add(cleaned, opts) do
    # Check for "-p <port>" flag if present
    {without_port_flag, flag_port} =
      case Regex.run(~r/\s+-p\s+(\d+)/, cleaned) do
        [full_match, p_str] ->
          {String.replace(cleaned, full_match, ""), String.to_integer(p_str)}

        nil ->
          {cleaned, nil}
      end

    # Extract user if present (user@...)
    {user, rest} =
      case String.split(without_port_flag, "@", parts: 2) do
        [u, r] -> {u, r}
        [r] -> {System.get_env("USER") || System.get_env("USERNAME") || "root", r}
      end

    # Extract address and port (:port)
    {address, port} =
      case String.split(rest, ":", parts: 2) do
        [addr, p_str] ->
          case Integer.parse(p_str) do
            {p, ""} -> {addr, p}
            _ -> {addr, flag_port || 22}
          end

        [addr] ->
          {addr, flag_port || 22}
      end

    trimmed_addr = String.trim(address)
    trimmed_user = String.trim(user)

    if trimmed_addr == "" do
      {:error, "Host address cannot be empty"}
    else
      id = Keyword.get(opts, :id, "#{trimmed_user}@#{trimmed_addr}:#{port}")
      name = Keyword.get(opts, :name, trimmed_addr)

      host = %__MODULE__{
        id: id,
        name: name,
        address: trimmed_addr,
        port: port,
        user: trimmed_user,
        auth_method: Keyword.get(opts, :auth_method, :key),
        identity_file: Keyword.get(opts, :identity_file),
        jump_host: Keyword.get(opts, :jump_host),
        group: Keyword.get(opts, :group),
        auth_order: Keyword.get(opts, :auth_order, [:key, :password, :keyboard_interactive]),
        connect_timeout: Keyword.get(opts, :connect_timeout, 10_000),
        poll_interval: Keyword.get(opts, :poll_interval, 5_000)
      }

      {:ok, host}
    end
  end
end
