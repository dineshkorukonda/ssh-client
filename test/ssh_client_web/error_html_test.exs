defmodule SSHClientWeb.ErrorHTMLTest do
  use ExUnit.Case, async: true

  alias SSHClientWeb.ErrorHTML

  test "renders 500.html with dark theme and proper document title" do
    rendered = ErrorHTML.render("500.html", %{}) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    assert rendered =~ "500"
    assert rendered =~ "Internal Server Error"
    assert rendered =~ "#050505"
    assert rendered =~ "Return to Servers"
  end

  test "renders 404.html with dark theme" do
    rendered = ErrorHTML.render("404.html", %{}) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    assert rendered =~ "404"
    assert rendered =~ "Page Not Found"
    assert rendered =~ "#050505"
  end
end
