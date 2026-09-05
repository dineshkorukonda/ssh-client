defmodule SSHClient.Config do
  @moduledoc """
  Loads and validates servers.yaml configuration for omarchy-server.
  """

  alias SSHClient.Config.Check
  alias SSHClient.Config.Server

  defstruct servers: []

  @type t :: %__MODULE__{
          servers: list(Server.t())
        }

  defmodule Error do
    defexception [:message]
  end

  @doc """
  Returns the default servers.json config file path using OS-correct paths.
  Priority:
  1. System env SSH_CLIENT_SERVERS_CONFIG or OMARCHY_SERVERS_CONFIG
  2. OS-specific user config dir (:filename.basedir(:user_config, "ssh-client"))
  3. Legacy fallback: ~/.config/omarchy/servers.json (if it exists)
  4. Legacy fallback: ~/.config/omarchy/servers.yaml (if it exists)
  5. Default OS-specific: Path.join(os_config_dir(), "servers.json")
  """
  @spec default_config_path() :: Path.t()
  def default_config_path do
    cond do
      env_path = System.get_env("SSH_CLIENT_SERVERS_CONFIG") || System.get_env("OMARCHY_SERVERS_CONFIG") ->
        Path.expand(env_path)

      File.exists?(Path.join(os_config_dir(), "servers.json")) ->
        Path.join(os_config_dir(), "servers.json")

      File.exists?(Path.expand("~/.config/omarchy/servers.json")) ->
        Path.expand("~/.config/omarchy/servers.json")

      File.exists?(Path.expand("~/.config/omarchy/servers.yaml")) ->
        Path.expand("~/.config/omarchy/servers.yaml")

      true ->
        Path.join(os_config_dir(), "servers.json")
    end
  end

  @doc """
  Returns the OS-correct user configuration directory for the application.
  Uses Erlang's `:filename.basedir/2` to resolve:
  - Windows: %APPDATA%/ssh-client
  - Linux: ~/.config/ssh-client (or $XDG_CONFIG_HOME/ssh-client)
  - macOS: ~/Library/Application Support/ssh-client
  """
  @spec os_config_dir() :: Path.t()
  def os_config_dir do
    case :filename.basedir(:user_config, "ssh-client") do
      dir when is_binary(dir) -> dir
      dir when is_list(dir) -> List.to_string(dir)
    end
  end

  @doc """
  Loads and parses configuration from a JSON or YAML file path.
  """
  @spec load_file(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        load_string(content)

      {:error, reason} ->
        {:error, "failed to read config file '#{path}': #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Loads the default configuration file from the OS-specific path.
  """
  @spec load_config() :: {:ok, t()} | {:error, String.t()}
  def load_config do
    load_file(default_config_path())
  end

  @doc """
  Saves a Config struct or list of servers to a JSON or YAML file path.
  Creates parent directories if necessary.
  """
  @spec save_file(t() | list(Server.t()), Path.t()) :: :ok | {:error, String.t()}
  def save_file(config_or_servers, path) when is_binary(path) do
    content =
      if String.ends_with?(path, [".yaml", ".yml"]) do
        dump_string(config_or_servers)
      else
        dump_json(config_or_servers)
      end

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      :ok
    else
      {:error, reason} ->
        {:error, "failed to write config file '#{path}': #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Serializes a Config struct or list of servers into a JSON formatted string.
  """
  @spec dump_json(t() | list(Server.t())) :: String.t()
  def dump_json(%__MODULE__{servers: servers}), do: dump_json(servers)

  def dump_json([]) do
    "{\"servers\":[]}\n"
  end

  def dump_json(servers) when is_list(servers) do
    data = %{
      "servers" =>
        Enum.map(servers, fn %Server{} = s ->
          base = %{
            "id" => s.id,
            "name" => s.name || s.id,
            "host" => s.host,
            "port" => s.port || 22
          }

          base = if s.user, do: Map.put(base, "user", s.user), else: base
          base = if s.proxy_jump, do: Map.put(base, "proxy_jump", s.proxy_jump), else: base

          if s.checks && s.checks != [] do
            checks_list =
              Enum.map(s.checks, fn %Check{type: type, name: name} ->
                %{"type" => to_string(type), "name" => name}
              end)

            Map.put(base, "checks", checks_list)
          else
            base
          end
        end)
    }

    :json.encode(data)
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  @doc """
  Serializes a Config struct or list of servers into a YAML formatted string.
  """
  @spec dump_string(t() | list(Server.t())) :: String.t()
  def dump_string(%__MODULE__{servers: servers}) do
    dump_string(servers)
  end

  def dump_string([]) do
    "servers: []\n"
  end

  def dump_string(servers) when is_list(servers) do
    lines = ["servers:"]

    server_blocks =
      Enum.map(servers, fn %Server{} = s ->
        dump_server(s)
      end)

    Enum.join(lines ++ server_blocks, "\n") <> "\n"
  end

  defp dump_server(%Server{} = s) do
    fields = [
      "  - id: #{s.id}",
      "    name: #{inspect(s.name || s.id)}",
      "    host: #{s.host}",
      "    port: #{s.port || 22}"
    ]

    fields =
      if s.user do
        fields ++ ["    user: #{s.user}"]
      else
        fields
      end

    fields =
      if s.proxy_jump do
        fields ++ ["    proxy_jump: #{s.proxy_jump}"]
      else
        fields
      end

    fields =
      if s.checks && s.checks != [] do
        check_lines =
          Enum.flat_map(s.checks, fn %Check{} = c ->
            [
              "      - type: #{c.type}",
              "        name: #{c.name}"
            ]
          end)

        fields ++ ["    checks:"] ++ check_lines
      else
        fields
      end

    Enum.join(fields, "\n")
  end

  @doc """
  Loads and parses configuration from a YAML file path, raising on error.
  """
  @spec load_file!(Path.t()) :: t()
  def load_file!(path) do
    case load_file(path) do
      {:ok, config} -> config
      {:error, reason} -> raise Error, message: reason
    end
  end

  @doc """
  Loads and parses configuration from a JSON or YAML string.
  """
  @spec load_string(String.t()) :: {:ok, t()} | {:error, String.t()}
  def load_string(content) when is_binary(content) do
    trimmed = String.trim_leading(content)

    if String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") do
      case decode_json_string(content) do
        {:ok, data} ->
          parse_data(data)

        {:error, reason} ->
          {:error, "invalid JSON syntax: #{reason}"}
      end
    else
      case YamlElixir.read_from_string(content) do
        {:ok, data} ->
          parse_data(data)

        {:error, %YamlElixir.ParsingError{message: message}} ->
          {:error, "invalid YAML syntax: #{message}"}

        {:error, reason} ->
          {:error, "invalid YAML: #{inspect(reason)}"}
      end
    end
  end

  defp decode_json_string(content) do
    try do
      {:ok, :json.decode(content)}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Loads and parses configuration from a YAML string, raising on error.
  """
  @spec load_string!(String.t()) :: t()
  def load_string!(yaml_string) do
    case load_string(yaml_string) do
      {:ok, config} -> config
      {:error, reason} -> raise Error, message: reason
    end
  end

  defp parse_data(%{"servers" => servers}) when is_list(servers) do
    parse_servers_list(servers)
  end

  defp parse_data(servers) when is_list(servers) do
    parse_servers_list(servers)
  end

  defp parse_data(%{}) do
    {:error, "config must contain a 'servers' key with a list of servers"}
  end

  defp parse_data(nil) do
    {:error, "config is empty"}
  end

  defp parse_data(_invalid) do
    {:error, "config must be a map with a 'servers' key or a list of servers"}
  end

  defp parse_servers_list(servers) do
    Enum.reduce_while(servers, {:ok, []}, fn server_data, {:ok, acc} ->
      case Server.from_map(server_data) do
        {:ok, server} -> {:cont, {:ok, [server | acc]}}
        {:error, reason} -> {:halt, {:error, "invalid server entry: #{reason}"}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, %__MODULE__{servers: Enum.reverse(list)}}
      error -> error
    end
  end
end
