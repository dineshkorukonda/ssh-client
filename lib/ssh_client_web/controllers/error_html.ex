defmodule SSHClientWeb.ErrorHTML do
  use Phoenix.Component

  def render("404.html", _assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="theme-color" content="#050505" />
        <title>404 — Page Not Found</title>
        <style>
          body { margin: 0; background: #050505; color: #e4e4e7; font-family: monospace; display: flex; align-items: center; justify-content: center; height: 100vh; text-align: center; }
          a { color: #38bdf8; text-decoration: none; border: 1px solid #27272a; padding: 8px 16px; border-radius: 8px; margin-top: 16px; display: inline-block; font-size: 13px; }
          a:hover { background: #18181b; }
        </style>
      </head>
      <body>
        <div>
          <h1 style="font-size: 2.5rem; margin: 0; color: #ef4444; font-weight: 600;">404</h1>
          <p style="color: #71717a; margin-top: 8px; font-size: 14px;">Page Not Found</p>
          <a href="/hosts">Return to Servers</a>
        </div>
      </body>
    </html>
    """
  end

  def render("500.html", _assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="theme-color" content="#050505" />
        <title>500 — Internal Server Error</title>
        <style>
          body { margin: 0; background: #050505; color: #e4e4e7; font-family: monospace; display: flex; align-items: center; justify-content: center; height: 100vh; text-align: center; }
          a { color: #38bdf8; text-decoration: none; border: 1px solid #27272a; padding: 8px 16px; border-radius: 8px; margin-top: 16px; display: inline-block; font-size: 13px; }
          a:hover { background: #18181b; }
        </style>
      </head>
      <body>
        <div>
          <h1 style="font-size: 2.5rem; margin: 0; color: #ef4444; font-weight: 600;">500</h1>
          <p style="color: #71717a; margin-top: 8px; font-size: 14px;">Internal Server Error</p>
          <a href="/hosts">Return to Servers</a>
        </div>
      </body>
    </html>
    """
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
