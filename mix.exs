defmodule Cucumber.MixProject do
  use Mix.Project

  @source_url "https://github.com/huddlz-hq/cucumber"
  @version "0.5.0"
  @description "Cucumber for Elixir: BDD testing framework with Gherkin syntax"

  def project do
    [
      app: :cucumber,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: @description,
      package: package(),
      docs: docs(),
      name: "Cucumber",
      source_url: @source_url
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.watch": :test,
        precommit: :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_parsec, "~> 1.4"},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Micah Woods"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md docs)
    ]
  end

  defp docs do
    [
      main: "getting_started",
      source_url: @source_url,
      extras: [
        "docs/getting_started.md",
        "docs/feature_files.md",
        "docs/step_definitions.md",
        "docs/hooks.md",
        "docs/error_handling.md",
        "docs/best_practices.md",
        "docs/architecture.md"
      ],
      groups_for_extras: [
        Guides: Path.wildcard("docs/*.md")
      ]
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "format",
        "test"
      ]
    ]
  end
end
