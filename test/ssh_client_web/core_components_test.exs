defmodule SSHClientWeb.CoreComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import SSHClientWeb.CoreComponents

  test "top_navigation renders logo, version, tabs, and command palette hint" do
    html =
      render_component(&top_navigation/1,
        current_tab: :hosts,
        version: "0.0.38",
        servers_count: 3,
        online_count: 2
      )

    assert html =~ "ssh-client"
    assert html =~ "v0.0.38"
    assert html =~ "Hosts"
    assert html =~ "Terminal"
    assert html =~ "SFTP"
    assert html =~ "Logs"
    assert html =~ "Settings"
    assert html =~ "Ctrl+K" or html =~ "⌘K" or html =~ "Ctrl + K"
  end

  test "stat_card renders title, value, and subtext" do
    html =
      render_component(&stat_card/1,
        title: "Total Servers",
        value: 12,
        subtext: "Across 3 clusters"
      )

    assert html =~ "TOTAL SERVERS" or html =~ "Total Servers"
    assert html =~ "12"
    assert html =~ "Across 3 clusters"
  end

  test "status_badge renders with appropriate badge style" do
    html = render_component(&status_badge/1, status: "connected")
    assert html =~ "connected"
    assert html =~ "text-emerald-500"
  end

  test "metric_bar renders progress bar with percentage" do
    html = render_component(&metric_bar/1, label: "CPU", value: 45.2)
    assert html =~ "CPU"
    assert html =~ "45.2%"
  end

  test "empty_state renders title and description" do
    html =
      render_component(&empty_state/1,
        title: "No Servers Configured",
        description: "Add an SSH server to get started."
      )

    assert html =~ "No Servers Configured"
    assert html =~ "Add an SSH server to get started."
  end

  test "breadcrumb renders path items" do
    items = [
      %{label: "Home", click: "nav_home", path: "/"},
      %{label: "etc", click: "nav_dir", path: "/etc"},
      %{label: "nginx"}
    ]

    html = render_component(&breadcrumb/1, items: items)
    assert html =~ "Home"
    assert html =~ "etc"
    assert html =~ "nginx"
  end

  test "modal renders when show is true and omits when false" do
    assigns = %{}

    hidden_html =
      rendered_to_string(~H"""
      <.modal id="test-modal" show={false}>
        Modal Content
      </.modal>
      """)

    refute hidden_html =~ "Modal Content"

    shown_html =
      rendered_to_string(~H"""
      <.modal id="test-modal" show={true} title="Test Title">
        Modal Content
      </.modal>
      """)

    assert shown_html =~ "Test Title"
    assert shown_html =~ "Modal Content"
  end
end
