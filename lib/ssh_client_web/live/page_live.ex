defmodule SSHClientWeb.PageLive do
  @moduledoc """
  Status / hello page LiveView.
  """

  use Phoenix.LiveView, layout: {SSHClientWeb.Layouts, :app}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "ssh-client")
      |> assign(:app_status, :ready)
      |> assign(:platform, detect_os())
      |> assign(:version, "0.0.1")

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-center h-full bg-[#050505] text-zinc-400 text-sm font-mono">
      ssh-client v{@version} — {@platform}
    </div>
    """
  end

  def detect_os do
    case :os.type() do
      {:win32, _} -> "Windows"
      {:unix, :darwin} -> "macOS"
      {:unix, _} -> "Linux"
      _ -> "Unknown"
    end
  end
end
