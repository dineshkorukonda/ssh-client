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
    host_str = normalize_host_param(host)
    extra_opts = extract_extra_opts(connect_opts)

    cond do
      # Test or explicit override
      Keyword.get(extra_opts, :silently_accept_hosts, false) ->
        true

      Keyword.get(extra_opts, :accept_host_key, false) ->
        HostKeyVerifier.save_host_key(host_str, port, key, extra_opts)
        true

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
    :ssh_file.user_key(algorithm, connect_opts)
  end

  @impl :ssh_client_key_api
  def add_host_key(host, port, key, connect_opts) do
    extra_opts = extract_extra_opts(connect_opts)
    HostKeyVerifier.save_host_key(normalize_host_param(host), port, key, extra_opts)
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
    connect_opts
  end

  defp extract_extra_opts(_), do: []

  defp notify_host_key_event(event_type, details, opts) do
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
