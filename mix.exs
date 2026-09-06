defmodule Cucumber.MixProject do
  use Mix.Project

  @source_url "https://github.com/huddlz-hq/cucumber"
  @version "1.0.0"
  @description "Cucumber for Elixir: BDD testing framework with Gherkin syntax"

  def project do
    [
      app: :cucumber,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: @description,
      package: package(),
      docs: docs(),
      name: "Cucumber",
      source_url: @source_url,
      # Ignore Cucumber feature files (not *_test.exs pattern)
      test_ignore_filters: [
        ~r/features\/step_definitions/,
        ~r/features\/support/
      ]
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_parsec, "~> 1.4"},
      {:igniter, "~> 0.8.3", optional: true},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
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
        "docs/attachments.md",
        "docs/error_handling.md",
        "docs/best_practices.md",
        "docs/architecture.md",
        "docs/compatibility.md"
      ],
      groups_for_extras: [
        Guides: Path.wildcard("docs/*.md")
      ]
    ]
  end

  defp aliases do
    [
      precommit: [
        "hex.audit",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "deps.unlock --check-unused",
        "test",
        "cmd bash scripts/test_release.sh",
        "cmd env MIX_ENV=dev mix do hex.build + compile --warnings-as-errors + docs --warnings-as-errors"
      ]
    ]
  end
end
