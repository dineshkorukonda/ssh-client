defmodule SSHClient.SSH.Auth do
  @moduledoc """
  Authentication handler and callback module for Erlang/OTP `:ssh`.
  Supports key-based, password, and keyboard-interactive authentication with
  per-host order overrides and identity discovery.
  """

  alias SSHClient.Host

  @default_auth_order [:key, :password, :keyboard_interactive]
  @standard_key_names ["id_ed25519", "id_rsa", "id_ecdsa"]

  @doc """
  Finds private key identities in priority order:
  1. Custom identity path (if provided and exists)
  2. Standard identities in user_dir: id_ed25519, then id_rsa, then id_ecdsa.
  """
  @spec resolve_identities(keyword() | map()) :: list(String.t())
  def resolve_identities(opts \\ []) do
    custom_path = get_opt(opts, :identity_file)
    user_dir = get_opt(opts, :user_dir) || Path.expand("~/.ssh")
    key_names = get_opt(opts, :standard_key_names) || @standard_key_names

    custom_identities =
      if custom_path && File.exists?(Path.expand(custom_path)) do
        [Path.expand(custom_path)]
      else
        []
      end

    standard_identities =
      key_names
      |> Enum.map(&Path.join(user_dir, &1))
      |> Enum.filter(&File.exists?/1)

    (custom_identities ++ standard_identities)
    |> Enum.uniq()
  end

  @doc """
  Converts an auth order list (e.g. `[:key, :password, :keyboard_interactive]`)
  into Erlang `:ssh` `:auth_methods` option format (comma-separated charlist).
  """
  @spec auth_methods_for_order(list(atom() | String.t()) | atom() | nil) :: charlist()
  def auth_methods_for_order(nil), do: auth_methods_for_order(@default_auth_order)

  def auth_methods_for_order(single_method) when is_atom(single_method) do
    auth_methods_for_order([single_method])
  end

  def auth_methods_for_order(order) when is_list(order) do
    order
    |> Enum.map(&normalize_method/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(",")
    |> String.to_charlist()
  end

  defp normalize_method(:key), do: "publickey"
  defp normalize_method("key"), do: "publickey"
  defp normalize_method(:publickey), do: "publickey"
  defp normalize_method("publickey"), do: "publickey"
  defp normalize_method(:agent), do: "publickey"
  defp normalize_method("agent"), do: "publickey"
  defp normalize_method(:password), do: "password"
  defp normalize_method("password"), do: "password"
  defp normalize_method(:keyboard_interactive), do: "keyboard-interactive"
  defp normalize_method("keyboard_interactive"), do: "keyboard-interactive"
  defp normalize_method("keyboard-interactive"), do: "keyboard-interactive"
  defp normalize_method(_), do: nil

  @doc """
  Builds a generic keyboard-interactive callback for OTP `:ssh`.
  Accepts either:
  - A callback function `fun(name, instruction, prompts)` returning `answers`
  - A map of `%{prompt_substring => answer}`
  - A static answer string (e.g. password fallback)
  """
  @spec build_keyboard_interactive_fun(
          (String.t(), String.t(), list({String.t(), boolean()}) -> list(String.t()))
          | map()
          | String.t()
        ) ::
          (charlist(), charlist(), list({charlist(), boolean()}) -> list(charlist()))
  def build_keyboard_interactive_fun(fun) when is_function(fun, 3) do
    fn name, instruction, prompts ->
      name_str = to_string(name)
      instr_str = to_string(instruction)

      prompts_elixir =
        Enum.map(prompts, fn {prompt_text, echo_bool} ->
          {to_string(prompt_text), echo_bool}
        end)

      answers = fun.(name_str, instr_str, prompts_elixir)

      Enum.map(answers, fn ans ->
        ans |> to_string() |> String.to_charlist()
      end)
    end
  end

  def build_keyboard_interactive_fun(answer_map) when is_map(answer_map) do
    build_keyboard_interactive_fun(fn _name, _instruction, prompts ->
      Enum.map(prompts, fn {prompt_text, _echo} ->
        found_entry =
          Enum.find(answer_map, fn {pattern, _val} ->
            String.contains?(String.downcase(prompt_text), String.downcase(to_string(pattern)))
          end)

        case found_entry do
          {_pattern, ans} -> to_string(ans)
          nil -> ""
        end
      end)
    end)
  end

  def build_keyboard_interactive_fun(static_answer) when is_binary(static_answer) do
    build_keyboard_interactive_fun(fn _name, _instruction, prompts ->
      Enum.map(prompts, fn _ -> static_answer end)
    end)
  end

  @doc """
  Builds authentication options for `:ssh.connect/4` from a `%Host{}` or options map.
  """
  @spec build_options(Host.t() | map(), keyword()) :: keyword()
  def build_options(host_or_map, extra_opts \\ [])

  def build_options(%Host{} = host, extra_opts) do
    explicit_method = Keyword.get(extra_opts, :auth_method) || host.default_auth_method || host.auth_method

    default_order =
      if explicit_method in [:password, "password"] or Keyword.has_key?(extra_opts, :password) do
        [:password, :keyboard_interactive, :key]
      else
        @default_auth_order
      end

    order =
      Keyword.get(extra_opts, :auth_order) ||
        (if explicit_method in [:password, "password"], do: default_order, else: host.auth_order) ||
        default_order

    identity = host.identity_file

    opts =
      extra_opts
      |> Keyword.put_new(:auth_order, order)
      |> maybe_put_identity(identity)

    do_build_options(opts)
  end

  def build_options(map, extra_opts) when is_map(map) do
    explicit_method =
      Keyword.get(extra_opts, :auth_method) ||
        Map.get(map, :default_auth_method) ||
        Map.get(map, "default_auth_method") ||
        Map.get(map, :auth_method) ||
        Map.get(map, "auth_method")

    default_order =
      if explicit_method in [:password, "password"] or Keyword.has_key?(extra_opts, :password) do
        [:password, :keyboard_interactive, :key]
      else
        @default_auth_order
      end

    order =
      Keyword.get(extra_opts, :auth_order) ||
        (if explicit_method in [:password, "password"], do: default_order, else: Map.get(map, :auth_order) || Map.get(map, "auth_order")) ||
        default_order

    identity = Map.get(map, :identity_file) || Map.get(map, "identity_file")

    opts =
      extra_opts
      |> Keyword.put_new(:auth_order, order)
      |> maybe_put_identity(identity)

    do_build_options(opts)
  end

  defp maybe_put_identity(opts, nil), do: opts
  defp maybe_put_identity(opts, path), do: Keyword.put_new(opts, :identity_file, path)

  defp do_build_options(opts) do
    auth_order = Keyword.get(opts, :auth_order, @default_auth_order)
    auth_methods = auth_methods_for_order(auth_order)

    base = [auth_methods: auth_methods]

    # Password option
    base =
      case Keyword.get(opts, :password) do
        nil ->
          base

        pwd when is_binary(pwd) ->
          [{:password, String.to_charlist(pwd)} | base]

        pwd when is_list(pwd) ->
          [{:password, pwd} | base]
      end

    # Keyboard-interactive callback option
    base =
      case Keyword.get(opts, :keyboard_interact_fun) do
        nil ->
          case Keyword.get(opts, :password) do
            pwd when is_binary(pwd) and pwd != "" ->
              [{:keyboard_interact_fun, build_keyboard_interactive_fun(pwd)} | base]

            pwd when is_list(pwd) and pwd != [] ->
              [{:keyboard_interact_fun, build_keyboard_interactive_fun(to_string(pwd))} | base]

            _ ->
              base
          end

        kbi_fun when is_function(kbi_fun, 3) ->
          [{:keyboard_interact_fun, build_keyboard_interactive_fun(kbi_fun)} | base]

        handler when is_map(handler) or is_binary(handler) ->
          [{:keyboard_interact_fun, build_keyboard_interactive_fun(handler)} | base]
      end

    # Identities and user_dir
    identities = resolve_identities(opts)

    case identities do
      [first_key | _] ->
        [{:user_dir, String.to_charlist(Path.dirname(first_key))} | base]

      [] ->
        case Keyword.get(opts, :user_dir) do
          nil ->
            base

          dir ->
            [{:user_dir, String.to_charlist(Path.expand(dir))} | base]
        end
    end
  end

  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp get_opt(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, to_string(key))
  end

  defp get_opt(_opts, _key), do: nil
end
