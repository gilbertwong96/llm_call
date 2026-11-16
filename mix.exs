defmodule LlmDialect.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/gilbertwong/llm_dialect"

  def project do
    [
      app: :llm_dialect,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Wire-protocol codec for LLM APIs: canonical IR, codec behaviours, and media adapters.",
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts/core"
      ],
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:spec_lint, "~> 0.1", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:igniter, "~> 0.8.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib docs/design.md README.md CHANGELOG.md CONTRIBUTING.md LICENSE
                mix.exs .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "docs/design.md"],
      source_url: @source_url
    ]
  end

  # ExDNA runs with its defaults: any clone fails the gate. Shared logic lives in
  # LlmDialect.Protocol.Helpers and the two adapter macros, so the adapters keep
  # their protocol-specific parts without duplicating them.
  @max_clones 0

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "spec_lint --warnings-as-errors",
        "ex_dna --max-clones #{@max_clones}",
        "reach.check --arch"
      ]
    ]
  end
end
