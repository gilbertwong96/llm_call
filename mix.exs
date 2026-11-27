defmodule LlmCall.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/gilbertwong96/llm_call"

  def project do
    [
      app: :llm_call,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "LLM wire-protocol codecs with a canonical IR, a one-call client on Finch, and a replaceable JSON layer.",
      package: package(),
      docs: docs(),
      test_coverage: [
        summary: [threshold: 85],
        ignore_modules: [~r/^LlmCall\.Examples\./]
      ],
      dialyzer: [
        plt_add_apps: [:ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts/core"
      ],
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LlmCall.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "examples"]
  defp elixirc_paths(:dev), do: ["lib", "examples"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:finch, "~> 0.25"},
      {:mint, "~> 1.4"},
      {:mint_web_socket, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:tool_call, "~> 0.4"},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:spec_lint, "~> 0.1", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib docs/design.md docs/roadmap.md README.md CHANGELOG.md CONTRIBUTING.md
                LICENSE mix.exs .formatter.exs)
    ]
  end

  defp docs do
    [
      filter_modules: ~r/^Elixir\.LlmCall(?!\.Examples)/,
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "docs/design.md",
        "docs/roadmap.md"
      ],
      source_url: @source_url
    ]
  end

  # The gate runs ExDNA with --max-clones 0: any clone fails it. Shared logic
  # lives in LlmCall.Dialect.Helpers and the two adapter macros, so the adapters
  # keep their protocol-specific parts without duplicating them.
  @max_clones 0

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test --cover",
        "credo --strict",
        "dialyzer",
        "spec_lint --warnings-as-errors",
        "ex_dna --max-clones #{@max_clones}",
        "reach.check --arch"
      ]
    ]
  end
end
