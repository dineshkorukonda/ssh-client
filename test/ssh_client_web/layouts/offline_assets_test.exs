defmodule SSHClientWeb.OfflineAssetsTest do
  use ExUnit.Case, async: true

  test "root layout contains no external CDN or Google Font references" do
    content = File.read!("lib/ssh_client_web/layouts/root.html.heex")
    refute content =~ "cdn.jsdelivr.net"
    refute content =~ "fonts.googleapis.com"
    refute content =~ "fonts.gstatic.com"
    refute content =~ "unpkg.com"
    refute content =~ "cdnjs.cloudflare.com"
  end

  test "vendored static assets exist on disk" do
    assert File.exists?("priv/static/js/phoenix.min.js")
    assert File.exists?("priv/static/js/phoenix_live_view.min.js")
    assert File.exists?("priv/static/js/xterm.min.js")
    assert File.exists?("priv/static/js/xterm-addon-fit.min.js")
    assert File.exists?("priv/static/js/xterm-addon-search.min.js")
    assert File.exists?("priv/static/css/xterm.min.css")
  end

  test "root layout references vendored local assets" do
    content = File.read!("lib/ssh_client_web/layouts/root.html.heex")
    assert content =~ ~s(href="/css/xterm.min.css")
    assert content =~ ~s(src="/js/xterm.min.js")
    assert content =~ ~s(src="/js/xterm-addon-fit.min.js")
    assert content =~ ~s(src="/js/phoenix.min.js")
    assert content =~ ~s(src="/js/phoenix_live_view.min.js")
  end
end
