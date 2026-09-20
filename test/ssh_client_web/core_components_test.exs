defmodule SSHClientWeb.CoreComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.Component
  import SSHClientWeb.CoreComponents

  describe "app_shell/1 component" do
    test "renders layout structure with topbar, sidebar, and breadcrumbs" do
      assigns = %{
        current_tab: :hosts,
        version: "0.0.52",
        servers_count: 5,
        online_count: 3,
        breadcrumbs: [%{label: "ssh-client", to: "/"}, %{label: "Hosts", to: nil}]
      }

      html =
        rendered_to_string(~H"""
        <.app_shell
          current_tab={@current_tab}
          version={@version}
          servers_count={@servers_count}
          online_count={@online_count}
          breadcrumbs={@breadcrumbs}
        >
          <div id="test-content">Dashboard Content</div>
        </.app_shell>
        """)

      assert html =~ "ssh-client"
      assert html =~ "v0.0.52"
      assert html =~ "3/5"
      assert html =~ "test-content"
      assert html =~ "Dashboard Content"
      assert html =~ "Hosts"
      assert html =~ "Terminal"
      assert html =~ "SFTP"
      assert html =~ "Logs"
      assert html =~ "Settings"
    end
  end

  describe "page_header/1 component" do
    test "renders title and subtitle properly" do
      assigns = %{
        title: "Managed Infrastructure",
        subtitle: "5 endpoints configured across clusters"
      }

      html =
        rendered_to_string(~H"""
        <.page_header title={@title} subtitle={@subtitle}>
          <button type="button">Action</button>
        </.page_header>
        """)

      assert html =~ "Managed Infrastructure"
      assert html =~ "5 endpoints configured across clusters"
      assert html =~ "Action"
    end
  end

  describe "console_toolbar/1 component" do
    test "renders container slot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.console_toolbar>
          <span>Filter Controls</span>
        </.console_toolbar>
        """)

      assert html =~ "Filter Controls"
    end
  end
end
