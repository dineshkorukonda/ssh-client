defmodule SSHClient.DesktopKeys do
  @moduledoc "Local SSH identity metadata; private keys and passphrases never enter SQLite."
  alias SSHClient.Store

  def list, do: Store.list(:keys)
  def remove(id), do: Store.delete(:keys, id)

  @max_key_size 262_144

  @doc "Inspect a local private key without registering it or storing its contents."
  def inspect_file(attrs) do
    path = attrs["path"]

    with true <- is_binary(path) and byte_size(path) in 1..4096,
         path = Path.expand(path),
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= @max_key_size,
         {:ok, data} <- File.read(path) do
      case inspect_key(data, path, attrs["passphrase"] || "") do
        {:ok, _, nil} ->
          {:error, "This is a public key. Choose the private key file without .pub."}

        {:ok, public, private_path} ->
          with {:ok, entry} <- metadata(public, private_path, Path.basename(path)) do
            {:ok,
             Map.merge(entry, %{
               status: "ready",
               source: "local",
               is_passphrase_protected: encrypted?(data)
             })}
          end

        {:error, _} = error ->
          unsupported = openssh_bcrypt?(data)

          if unsupported and (attrs["passphrase"] || "") != "" do
            {:error,
             "Encrypted OpenSSH keys use bcrypt, which the bundled SSH engine cannot decrypt. Choose an unencrypted OpenSSH key or an encrypted PEM key."}
          else
            if encrypted?(data) and (attrs["passphrase"] || "") == "" do
              public = encrypted_public(data, path)

              entry =
                case public && metadata(public, path, Path.basename(path)) do
                  {:ok, entry} ->
                    entry

                  _ ->
                    %{
                      id: path,
                      name: Path.basename(path),
                      private_key_path: path,
                      algorithm: "Encrypted key",
                      fingerprint: "",
                      public_key: ""
                    }
                end

              {:ok,
               Map.merge(entry, %{
                 status: if(unsupported, do: "unsupported", else: "locked"),
                 source: "local",
                 is_passphrase_protected: true
               })}
            else
              error
            end
          end
      end
    else
      false -> {:error, "Choose a private key file smaller than 256 KB."}
      {:error, reason} -> {:error, "Cannot read this key: #{:file.format_error(reason)}"}
    end
  rescue
    _ -> {:error, "Cannot inspect this SSH key. Check its format and permissions."}
  end

  @doc "Discover private keys in .ssh and explicit IdentityFile paths; never search the home tree."
  def discover(opts \\ []) do
    home =
      Keyword.get(
        opts,
        :home,
        Application.get_env(:ssh_client, :ssh_home) || System.get_env("SSH_CLIENT_SSH_HOME") ||
          System.user_home!()
      )

    directory = Path.join(home, ".ssh")

    files =
      case File.ls(directory) do
        {:ok, names} ->
          names |> Enum.sort() |> Enum.take(200) |> Enum.map(&Path.join(directory, &1))

        _ ->
          []
      end

    config_path = Path.join(directory, "config")

    config =
      with {:ok, stat} <- File.stat(config_path),
           true <- stat.type == :regular and stat.size <= 2_000_000,
           do: SSHClient.SSH.ConfigImporter.import_file(config_path)

    configured =
      case config do
        {:ok, hosts} -> Enum.map(hosts, & &1.identity_file) |> Enum.reject(&is_nil/1)
        _ -> []
      end

    (configured ++ files)
    |> Enum.uniq()
    |> Enum.take(200)
    |> Enum.flat_map(fn path ->
      if String.ends_with?(path, [".pub", "known_hosts", "authorized_keys", "/config"]) do
        []
      else
        case inspect_file(%{"path" => path}) do
          {:ok, entry} -> [entry]
          _ -> []
        end
      end
    end)
  end

  defp openssh_wire(data) do
    encoded =
      data
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "-----"))
      |> Enum.map(&String.trim/1)
      |> Enum.join()

    with {:ok, <<"openssh-key-v1", 0, rest::binary>>} <- Base.decode64(encoded), do: {:ok, rest}
  end

  defp ssh_string(<<size::32, value::binary-size(size), rest::binary>>), do: {:ok, value, rest}
  defp ssh_string(_), do: {:error, :invalid_key}

  defp encrypted?(data) do
    if String.contains?(data, "BEGIN OPENSSH PRIVATE KEY") do
      with {:ok, wire} <- openssh_wire(data),
           {:ok, cipher, _} <- ssh_string(wire),
           do: cipher != "none"
    else
      String.contains?(data, ["BEGIN ENCRYPTED PRIVATE KEY", "Proc-Type: 4,ENCRYPTED"])
    end
    |> then(&(&1 == true))
  end

  defp openssh_bcrypt?(data) do
    result =
      with {:ok, wire} <- openssh_wire(data),
           {:ok, _, rest} <- ssh_string(wire),
           {:ok, kdf, _} <- ssh_string(rest),
           do: kdf == "bcrypt"

    result == true
  end

  defp encrypted_public(data, path) do
    with {:ok, wire} <- openssh_wire(data),
         {:ok, _, rest} <- ssh_string(wire),
         {:ok, _, rest} <- ssh_string(rest),
         {:ok, _, <<1::32, rest::binary>>} <- ssh_string(rest),
         {:ok, public, _} <- ssh_string(rest),
         {:ok, algorithm, _} <- ssh_string(public) do
      algorithm <> " " <> Base.encode64(public)
    else
      _ ->
        with {:ok, stat} <- File.stat(path <> ".pub"),
             true <- stat.size <= @max_key_size,
             {:ok, public} <- File.read(path <> ".pub"),
             {:ok, _, nil} <- inspect_key(public, path <> ".pub", "") do
          public
        else
          _ -> nil
        end
    end
  end

  def register(attrs) do
    path = attrs["path"]

    if is_binary(path) and byte_size(path) in 1..4096 do
      path = Path.expand(path)

      with {:ok, stat} <- File.stat(path),
           true <- stat.type == :regular and stat.size <= @max_key_size,
           {:ok, data} <- File.read(path),
           {:ok, public, private_path} <- inspect_key(data, path, attrs["passphrase"] || ""),
           {:ok, entry} <- metadata(public, private_path, attrs["name"] || Path.basename(path)),
           entry = Map.put(entry, :is_passphrase_protected, encrypted?(data)),
           :ok <- Store.put(:keys, entry.id, entry) do
        {:ok, entry}
      else
        false -> {:error, "Choose an SSH key file smaller than 256 KB."}
        error -> error
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

      Enum.find_value(
        [
          :"ssh-ed25519",
          :"ssh-rsa",
          :"ecdsa-sha2-nistp256",
          :"ecdsa-sha2-nistp384",
          :"ecdsa-sha2-nistp521"
        ],
        fn algorithm ->
          case :ssh_file.decode_ssh_file(:private, algorithm, data, password) do
            {:ok, [{key, _} | _]} -> {:ok, public_text(key), path}
            _ -> nil
          end
        end
      ) || {:error, "Unsupported or encrypted private key; check its passphrase."}
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
