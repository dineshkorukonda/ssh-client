defmodule SSHClientWeb.OSBadgeTest do
  use ExUnit.Case, async: true
  require Phoenix.LiveViewTest
  alias SSHClientWeb.CoreComponents

  test "OS labels handle missing metadata and retain the monochrome palette" do
    assert CoreComponents.detect_os(nil) == :server
    assert CoreComponents.detect_os(%{name: "Ubuntu gateway", tags: nil}) == :ubuntu
    assert CoreComponents.detect_os(%{tags: ["debian"]}) == :debian

    for os <- [:ubuntu, :debian, :arch, :windows, :server] do
      html = Phoenix.LiveViewTest.render_component(&CoreComponents.os_badge/1, os: os)
      assert html =~ "text-muted-foreground"
      refute html =~ "#e95420"
      refute html =~ "#d70a53"
    end
  end
end
