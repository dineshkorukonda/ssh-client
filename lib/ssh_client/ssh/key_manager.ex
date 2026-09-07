defmodule SSHClient.SSH.KeyManager do
  @moduledoc """
  Discovers, inspects, and sanitizes local OpenSSH public keys.
  """

  @standard_public_keys [
    {"id_ed25519.pub", :ed25519},
    {"id_rsa.pub", :rsa},
    {"id_ecdsa.pub", :ecdsa}
  ]

  @doc """
  Resolves the local user's .ssh directory path.
  """
  @spec user_ssh_dir() :: Path.t()
  def user_ssh_dir do
    Path.expand("~/.ssh")
  end

  @doc """
  Lists all available public keys found in the ssh directory.
  """
  @spec list_public_keys(keyword()) :: {:ok, list(map())}
  def list_public_keys(opts \\ []) do
    dir = Keyword.get(opts, :ssh_dir, user_ssh_dir())

    if File.dir?(dir) do
      keys =
        @standard_public_keys
        |> Enum.flat_map(fn {filename, type} ->
          path = Path.join(dir, filename)

          if File.exists?(path) do
            case File.read(path) do
              {:ok, content} ->
                trimmed = String.trim(content)

                case sanitize_public_key(trimmed) do
                  {:ok, clean} ->
                    comment = extract_comment(clean)
                    [%{type: type, filename: filename, path: path, content: clean, comment: comment}]

                  _ ->
                    []
                end

              _ ->
                []
            end
          else
            []
          end
        end)

      {:ok, keys}
    else
      {:ok, []}
    end
  end

  @doc """
  Returns the preferred default public key.
  """
  @spec get_default_public_key(keyword()) :: {:ok, map()} | {:error, :no_keys_found}
  def get_default_public_key(opts \\ []) do
    case list_public_keys(opts) do
      {:ok, [primary | _]} -> {:ok, primary}
      _ -> {:error, :no_keys_found}
    end
  end

  @doc """
  Validates that a public key string conforms to OpenSSH standard format and contains no shell injection chars.
  """
  @spec sanitize_public_key(String.t()) :: {:ok, String.t()} | {:error, :invalid_public_key}
  def sanitize_public_key(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    # Valid OpenSSH key format: (key-type) (base64) (optional comment)
    regex = ~r/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\s+([A-Za-z0-9+\/=]+)(\s+[^\r\n;`$|&><]*)?$/

    if Regex.match?(regex, trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_public_key}
    end
  end

  def sanitize_public_key(_), do: {:error, :invalid_public_key}

  defp extract_comment(content) do
    case String.split(content, ~r/\s+/, parts: 3) do
      [_, _, comment] -> String.trim(comment)
      _ -> ""
    end
  end
end
