defmodule SSHClient.Window do
  @moduledoc """
  Desktop window management using `elixir-desktop` / WebView2 (Windows) & WebKitGTK (Linux).
  """

  @doc """
  Launches the desktop window pointing to the local LiveView endpoint.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Resolves configuration options for the desktop window.
  """
  def config(opts \\ []) do
    port = Keyword.get(opts, :port, 4000)
    default_url = "http://127.0.0.1:#{port}"
    url = Keyword.get(opts, :url, default_url)
    title = Keyword.get(opts, :title, "ssh-client")
    size = Keyword.get(opts, :size, {1024, 720})

    %{
      port: port,
      url: url,
      title: title,
      size: size
    }
  end

  def start_link(opts \\ []) do
    cfg = config(opts)

    if Code.ensure_loaded?(Desktop.Window) do
      apply(Desktop.Window, :start_link, [
        [
          app: :ssh_client,
          id: SSHClientWindow,
          title: cfg.title,
          size: cfg.size,
          url: cfg.url
        ]
      ])
    else
      # Fallback when running headless or in test mode
      Task.start_link(fn -> Process.sleep(:infinity) end)
    end
  end
end
