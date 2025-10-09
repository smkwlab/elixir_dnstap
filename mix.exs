defmodule ElixirDnstap.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/smkwlab/elixir_dnstap"

  def project do
    [
      app: :elixir_dnstap,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex package information
      description: "DNSTap protocol implementation with Frame Streams support for Elixir",
      package: package(),

      # Documentation
      docs: docs(),

      # Test coverage
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirDnstap.Application, []}
    ]
  end

  defp deps do
    [
      # Required dependencies
      {:gen_stage, "~> 1.2"},
      {:protobuf, "~> 0.15"},

      # Development & Test dependencies
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp package do
    [
      name: "elixir_dnstap",
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Toshihiro Yamada"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "GenStage Pipeline": [
          ElixirDnstap.Producer,
          ElixirDnstap.BufferStage,
          ElixirDnstap.WriterConsumer
        ],
        "Writers": [
          ElixirDnstap.Writer.Behaviour,
          ElixirDnstap.Writer.File,
          ElixirDnstap.Writer.UnixSocket,
          ElixirDnstap.Writer.TCP
        ],
        "Protocol Implementation": [
          ElixirDnstap.Encoder,
          ElixirDnstap.FrameStreams
        ],
        "Configuration & Supervision": [
          ElixirDnstap.Application,
          ElixirDnstap.Supervisor,
          ElixirDnstap.Config
        ]
      ]
    ]
  end
end
