# Cucumber for Elixir

[![Hex.pm](https://img.shields.io/hexpm/v/cucumber.svg)](https://hex.pm/packages/cucumber)
[![Docs](https://img.shields.io/hexpm/v/cucumber.svg?color=blue&label=hexdocs)](https://hexdocs.pm/cucumber)

A behavior-driven development (BDD) testing framework for Elixir that enables writing executable specifications in natural language. Cucumber for Elixir bridges the gap between technical and non-technical stakeholders by allowing tests to be written in plain language while being executed as code.

Cucumber for Elixir is **CCK compliant**: the official [Cucumber Compatibility Kit](https://github.com/cucumber/compatibility-kit) runs as an approval suite in this repo, comparing the [Cucumber Messages](https://github.com/cucumber/messages) we emit against the reference implementation's output sample by sample.

## Features

- **Auto-discovery**: Automatically finds and runs feature files and step definitions
- **Gherkin Support**: Write tests in familiar Given/When/Then format, including `Rule:` groupings with their own backgrounds and tags
- **Markdown Feature Files**: Write features as Markdown documents (`.feature.md`) with prose alongside the executable Gherkin
- **Parameter Typing**: Define step patterns with typed parameters (`{string}`, `{int}`, `{float}`, `{word}`, `{atom}`), optional parameters (`{int?}`), optional text (`(s)`), alternation (`a/b`), and your own custom parameter types
- **Regex Steps**: Match steps with regular expressions when a cucumber expression won't cut it
- **Data Tables**: Pass structured data to your steps
- **DocStrings**: Include multi-line text blocks in your steps, with optional media types
- **Background Steps**: Define common setup steps for all scenarios
- **Scenario Outlines**: Run the same scenario with different data using Examples tables
- **Tag Filtering**: Run subsets of scenarios using tags
- **Async Test Execution**: Run feature tests concurrently with the `@async` tag
- **Hooks**: Run-level (`before_all`/`after_all`), scenario, and step hooks with tag-based filtering and optional names
- **Pending & Skipped Steps**: Halt a scenario as pending (fails) or skipped (doesn't) from any step or before-hook
- **Retry**: Re-run flaky scenarios via `config :cucumber, retry: n` or `@retry-n` tags
- **Attachments**: Attach screenshots, logs, and payloads to steps with `Cucumber.attach/4`
- **Cucumber Messages**: Emit the standard NDJSON message stream for cross-tool reporting
- **Context Passing**: Share state between steps with a simple context map
- **Enhanced Error Reporting**: Detailed error messages with clickable file:line references, step execution history, and formatted HTML output
- **ExUnit Integration**: Seamlessly integrates with Elixir's built-in test framework

## Installation

Add `cucumber` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:cucumber, "~> 0.9", only: [:dev, :test]}
  ]
end
```

## Quick Start

### 1. Add Cucumber to your test helper

In your `test/test_helper.exs`:

```elixir
ExUnit.start()
Cucumber.compile_features!()
```

### 2. Create a Feature File

Feature files use the Gherkin syntax and should be placed in `test/features/` with a `.feature` extension:

```gherkin
# test/features/calculator.feature
Feature: Basic Calculator

Scenario: Adding two numbers
  Given I have entered 50 into the calculator
  And I have entered 70 into the calculator
  When I press add
  Then the result should be 120 on the screen
```

Features can also be written as Markdown documents with a `.feature.md`
extension ([Markdown with Gherkin](https://github.com/cucumber/gherkin/blob/main/MARKDOWN_WITH_GHERKIN.md)):
headings carry the Gherkin keywords, steps are bullet-list items, tables are
indented Markdown tables, docstrings are fenced code blocks, tags are inline
code spans (`` `@wip` ``), and everything else is prose:

```markdown
# Feature: Basic Calculator

Anything that isn't Gherkin — like this paragraph — is documentation.

## Scenario: Adding two numbers

* Given I have entered 50 into the calculator
* And I have entered 70 into the calculator
* When I press add
* Then the result should be 120 on the screen
```

### 3. Create Step Definitions

Step definitions should be placed in `test/features/step_definitions/` with a `.exs` extension:

```elixir
# test/features/step_definitions/calculator_steps.exs
defmodule CalculatorSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "I have entered {int} into the calculator", %{args: [value]} = context do
    values = Map.get(context, :values, [])
    Map.put(context, :values, values ++ [value])
  end

  step "I press add", context do
    sum = Enum.sum(context.values)
    Map.put(context, :result, sum)
  end

  step "the result should be {int} on the screen", %{args: [expected]} = context do
    assert context.result == expected
    context
  end
end
```

### 4. Run Your Tests

```bash
# Run all tests including Cucumber
mix test

# Run only Cucumber tests
mix test --only cucumber

# Run specific feature
mix test --only feature_basic_calculator
```

## File Structure

By default, Cucumber expects the following structure:

```
test/
  features/
    authentication.feature
    shopping.feature
    step_definitions/
      authentication_steps.exs
      shopping_steps.exs
      common_steps.exs
```

You can customize paths in `config/test.exs`:

```elixir
config :cucumber,
  features: ["test/features/**/*.feature"],
  steps: ["test/features/step_definitions/**/*.exs"]
```

## Working with Data Tables

In your feature file:
```gherkin
Given I have the following items in my cart:
  | Product Name    | Quantity | Price  |
  | Smartphone      | 1        | 699.99 |
  | Protection Plan | 1        | 79.99  |
```

In your step definitions:
```elixir
step "I have the following items in my cart:", context do
  # Access the datatable
  datatable = context.datatable

  # Access headers
  headers = datatable.headers  # ["Product Name", "Quantity", "Price"]

  # Access rows as maps
  items = datatable.maps
  # [
  #   %{"Product Name" => "Smartphone", "Quantity" => "1", "Price" => "699.99"},
  #   %{"Product Name" => "Protection Plan", "Quantity" => "1", "Price" => "79.99"}
  # ]

  # Process the items
  Map.put(context, :cart_items, items)
end
```

## Async Test Execution

By default, Cucumber tests run synchronously. To enable concurrent execution for features that don't share state, add the `@async` tag:

```gherkin
@async
Feature: Independent Feature

Scenario: Concurrent scenario
  Given some precondition
  When something happens
  Then expect a result
```

Features marked with `@async` will run concurrently with other async tests, improving test suite performance. Only use this tag for features that:
- Don't share state with other tests
- Don't rely on test execution order
- Are truly independent

Note: Database tests can safely run async when using Ecto's SQL sandbox in shared mode.

## Hooks

Cucumber supports hooks that run before and after scenarios (plus run-level `before_all`/`after_all` and per-step hooks — see the [Hooks guide](https://hexdocs.pm/cucumber/hooks.html)). Before-scenario hooks run inside the test process, **before** background steps:

```elixir
# test/features/support/database_hooks.exs
defmodule DatabaseHooks do
  use Cucumber.Hooks

  # Global hook - runs for all scenarios
  before_scenario context do
    {:ok, Map.put(context, :started_at, DateTime.utc_now())}
  end

  # Tagged hook - runs for @database features/scenarios
  before_scenario "@database", context do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)

    if context.async do
      Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
    end

    {:ok, Map.put(context, :database_ready, true)}
  end

  after_scenario "@database", _context do
    :ok
  end
end
```

Hooks match against the combined tags from both the feature and the scenario:

```gherkin
@database
Feature: User Management
  Background:
    Given a user exists  # @database hook already ran, DB is ready

  Scenario: User logs in
    When the user logs in

  @admin
  Scenario: Admin manages users
    # Both @database and @admin hooks run for this scenario
    When the admin views all users
```

Execution order:
1. All matching before hooks run (global + feature tags + scenario tags), in definition order
2. Background steps execute
3. Scenario steps execute
4. After hooks run in reverse definition order — in the test process, on pass and on fail

## Documentation

For comprehensive documentation and guides, please visit [HexDocs](https://hexdocs.pm/cucumber).

- [Getting Started](https://hexdocs.pm/cucumber/getting_started.html)
- [Feature Files](https://hexdocs.pm/cucumber/feature_files.html)
- [Step Definitions](https://hexdocs.pm/cucumber/step_definitions.html)
- [Hooks](https://hexdocs.pm/cucumber/hooks.html) - Run-level, scenario, and step hooks
- [Attachments](https://hexdocs.pm/cucumber/attachments.html)
- [Error Handling](https://hexdocs.pm/cucumber/error_handling.html)
- [Best Practices](https://hexdocs.pm/cucumber/best_practices.html)
- [Architecture](https://hexdocs.pm/cucumber/architecture.html)

## License

Cucumber for Elixir is licensed under the MIT License. See [LICENSE](LICENSE) for the full license text.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.