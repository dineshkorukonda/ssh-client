defmodule SSHClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :ssh_client,
      version: "0.0.13",
      elixir: "~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "OTP-based lightweight SSH client and server manager with full-bleed terminal GUI for Windows and Linux.",
      package: package(),
      releases: [
        ssh_client: [
          include_executables_for: [:unix, :windows],
          applications: [
            runtime_tools: :permanent,
            inets: :permanent,
            ssl: :permanent,
            crypto: :permanent,
            public_key: :permanent
          ]
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssh, :inets, :ssl, :crypto, :public_key, :runtime_tools],
      mod: {SSHClient.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:yaml_elixir, "~> 2.12"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:floki, ">= 0.30.0", only: :test}
    ]
  end

  defp package do
    [
      name: "ssh_client",
      files: ~w(lib priv mix.exs README.md LICENSE),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/dineshkorukonda/ssh-client",
        "Website" => "https://ssh-client.dineshkorukonda.online"
      }
    ]
  end
end
