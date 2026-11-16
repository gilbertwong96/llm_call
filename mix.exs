defmodule LlmDialect.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/gilbertwong/llm_dialect"

  def project do
    [
      app: :llm_dialect,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Wire-protocol codec for LLM APIs: canonical IR, codec behaviours, and media adapters.",
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:ex_unit]],
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

  # ExDNA: no logic clone is allowed. `min_mass` 45 keeps the scan focused on
  # real duplication — above it are the extracted validators and decoders — and
  # ignores the alias preambles and one-line delegations every adapter shares by
  # construction. Shared logic lives in LlmDialect.Protocol.Helpers; a new clone
  # above the threshold fails `mix ci`.
  @max_clones 0
  @min_clone_mass 45

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones #{@max_clones} --min-mass #{@min_clone_mass}",
        "reach.check --arch --smells"
      ]
    ]
  end
end
