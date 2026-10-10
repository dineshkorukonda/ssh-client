defmodule SSHClient.SSH.KeyCallback do
  @moduledoc """
  Custom `:ssh_client_key_api` implementation for Erlang/OTP `:ssh`.
  Rejects changed or unknown host keys by default, delegates user private keys
  to `:ssh_file`, and integrates with `SSHClient.SSH.HostKeyVerifier`.
  """

  @behaviour :ssh_client_key_api

  alias SSHClient.SSH.HostKeyVerifier

  @impl :ssh_client_key_api
  def is_host_key(key, host, port, _algorithm, connect_opts) do
    extra_opts = extract_extra_opts(connect_opts)
    host_str = Keyword.get(extra_opts, :host_key_host, normalize_host_param(host))
    port = Keyword.get(extra_opts, :host_key_port, port)

    cond do
      # Test or explicit override
      Keyword.get(extra_opts, :silently_accept_hosts, false) ->
        true

      Keyword.get(extra_opts, :accept_host_key, false) ->
        HostKeyVerifier.save_host_key(host_str, port, key, extra_opts) == :ok

      true ->
        case HostKeyVerifier.verify(key, host_str, port, extra_opts) do
          {:ok, :trusted, _} ->
            true

          {:error, {:first_connect, details}} ->
            notify_host_key_event(:first_connect, details, extra_opts)
            false

          {:error, {:host_key_changed, details}} ->
            notify_host_key_event(:host_key_changed, details, extra_opts)
            false
        end
    end
  end

  @impl :ssh_client_key_api
  def user_key(algorithm, connect_opts) do
    opts = extract_extra_opts(connect_opts)

    case Keyword.get(opts, :identity_file) do
      path when is_binary(path) and path != "" ->
        passphrase = Keyword.get(opts, :passphrase, :ignore)

        passphrase =
          if is_binary(passphrase), do: String.to_charlist(passphrase), else: passphrase

        with {:ok, pem} <- File.read(Path.expand(path)),
             {:ok, [{key, _attrs} | _]} <-
               :ssh_file.decode_ssh_file(:private, algorithm, pem, passphrase) do
          {:ok, key}
        else
          {:error, reason} -> {:error, {:identity_file, reason}}
          _ -> {:error, {:identity_file, :no_key_found}}
        end

      _ ->
        :ssh_file.user_key(algorithm, connect_opts)
    end
  end

  @impl :ssh_client_key_api
  def add_host_key(host, port, key, connect_opts) do
    extra_opts = extract_extra_opts(connect_opts)

    HostKeyVerifier.save_host_key(
      Keyword.get(extra_opts, :host_key_host, normalize_host_param(host)),
      Keyword.get(extra_opts, :host_key_port, port),
      key,
      extra_opts
    )
  end

  defp normalize_host_param(host) when is_binary(host), do: host

  defp normalize_host_param(host) when is_list(host) do
    case host do
      [first | _] when is_binary(first) ->
        first

      [first | _] when is_list(first) ->
        to_string(first)

      _ ->
        try do
          to_string(host)
        rescue
          _ -> inspect(host)
        end
    end
  end

  defp normalize_host_param(host), do: to_string(host)

  defp extract_extra_opts(connect_opts) when is_list(connect_opts) do
    Keyword.merge(connect_opts, Keyword.get(connect_opts, :key_cb_private, []))
  end

  defp extract_extra_opts(_), do: []

  defp notify_host_key_event(event_type, details, opts) do
    details = Map.put(details, :known_hosts_file, HostKeyVerifier.known_hosts_path(opts))

    case Keyword.get(opts, :host_key_handler) do
      handler when is_function(handler, 2) ->
        handler.(event_type, details)

      pid when is_pid(pid) ->
        send(pid, {:ssh_host_key_event, event_type, details})

      _ ->
        :ok
    end
  end
end
