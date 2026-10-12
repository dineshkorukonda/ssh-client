defmodule SSHClient.DesktopKeys do
  @moduledoc "Local SSH identity metadata; private keys and passphrases never enter SQLite."
  alias SSHClient.Store

  def list, do: Store.list(:keys)
  def remove(id), do: Store.delete(:keys, id)

  def register(attrs) do
    path = attrs["path"]

    if is_binary(path) and byte_size(path) in 1..4096 do
      path = Path.expand(path)

      with {:ok, data} <- File.read(path),
           {:ok, public, private_path} <- inspect_key(data, path, attrs["passphrase"] || ""),
           {:ok, entry} <- metadata(public, private_path, attrs["name"] || Path.basename(path)),
           :ok <- Store.put(:keys, entry.id, entry) do
        {:ok, entry}
      end
    else
      {:error, "Select a valid SSH key file."}
    end
  rescue
    _ -> {:error, "Cannot decode this SSH key. Check its format and passphrase."}
  end

  def generate(attrs) do
    algorithm = attrs["algorithm"] || "ED25519"
    path = attrs["path"]

    if algorithm in ["ED25519", "RSA-4096"] and is_binary(path) and byte_size(path) in 1..4096 do
      path = Path.expand(path)

      if File.exists?(path) or File.exists?(path <> ".pub") do
        {:error, "Choose a new filename; existing keys will not be replaced."}
      else
        key =
          if algorithm == "ED25519",
            do: :public_key.generate_key({:namedCurve, :ed25519}),
            else: :public_key.generate_key({:rsa, 4096, 65_537})

        type = if algorithm == "ED25519", do: :ECPrivateKey, else: :RSAPrivateKey
        pem = :public_key.pem_encode([:public_key.pem_entry_encode(type, key)])
        public = key |> public_text() |> String.trim()

        with :ok <- write_new(path, pem),
             :ok <- write_new(path <> ".pub", public <> "\n") do
          register(%{"path" => path, "name" => attrs["name"] || Path.basename(path)})
        end
      end
    else
      {:error, "Choose ED25519 or RSA-4096 and a private-key destination."}
    end
  rescue
    _ -> {:error, "Key generation failed. Check the destination permissions."}
  end

  defp write_new(path, data) do
    with {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600), do: IO.binwrite(file, data)
      after
        File.close(file)
      end
    end
  end

  defp inspect_key(data, path, passphrase) do
    if String.starts_with?(String.trim(data), ["ssh-", "ecdsa-"]) do
      case :ssh_file.decode(data, :openssh_key) do
        [{key, _}] -> {:ok, public_text(key), nil}
        _ -> {:error, "Invalid SSH public key."}
      end
    else
      password = if passphrase == "", do: :ignore, else: String.to_charlist(passphrase)

      Enum.find_value([:"ssh-ed25519", :"ssh-rsa", :"ecdsa-sha2-nistp256"], fn algorithm ->
        case :ssh_file.decode_ssh_file(:private, algorithm, data, password) do
          {:ok, [{key, _} | _]} -> {:ok, public_text(key), path}
          _ -> nil
        end
      end) || {:error, "Unsupported or encrypted private key; check its passphrase."}
    end
  end

  defp public_text(key) when elem(key, 0) == :RSAPrivateKey,
    do: public_text({:RSAPublicKey, elem(key, 2), elem(key, 3)})

  defp public_text(key), do: :ssh_file.encode([{key, []}], :openssh_key) |> to_string()

  defp metadata(public, private_path, name) do
    [algorithm, encoded | _] = String.split(public)
    wire = Base.decode64!(encoded)
    fingerprint = "SHA256:" <> Base.encode64(:crypto.hash(:sha256, wire), padding: false)

    id =
      :crypto.hash(:sha256, to_string(private_path) <> fingerprint) |> Base.encode16(case: :lower)

    {:ok,
     %{
       id: id,
       name: String.slice(name, 0, 200),
       algorithm: algorithm,
       fingerprint: fingerprint,
       public_key: String.trim(public),
       private_key_path: private_path,
       created_at: Date.utc_today() |> Date.to_iso8601()
     }}
  end
end
