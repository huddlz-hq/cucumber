# Cucumber Architecture

This document provides an overview of the Cucumber implementation architecture, explaining the core components and how they interact.

## Core Components

```
Cucumber
  ├── Discovery (Feature/Step Finding)
  ├── Gherkin (Parser)
  ├── Expression (Parameter Matching)
  ├── Compiler (Test Generation)
  ├── Runtime (Step Execution)
  └── StepError (Error Reporting)
```

### Discovery System

The discovery system automatically finds and loads feature files and step definitions:

```elixir
Discovery.discover()
  ├── Scans for features (test/features/**/*.feature)
  ├── Loads step definitions (test/features/step_definitions/**/*.exs)
  └── Returns: %{features: [...], step_registry: %{...}}
```

### Gherkin Parser

The Gherkin parser uses NimbleParsec to parse `.feature` files into Elixir structs. It handles the syntax of Gherkin, including:

- Feature declarations with descriptions and tags
- Scenario outlines with Examples tables
- Backgrounds
- Steps (Given, When, Then, And, But, *)
- Data tables and doc strings
- Tags at feature, scenario, and examples levels

The parser is built using bottom-up combinator composition in six levels:
1. Primitives (whitespace, newlines)
2. Keywords (Given, When, Then, Feature:, etc.)
3. Elements (tags, datatables, docstrings)
4. Steps (keyword + text + attachments)
5. Scenarios (Background, Scenario, ScenarioOutline, Examples)
6. Feature (top-level parser)

```elixir
# Parser flow
Feature File (Text) → NimbleParsec Parser → Elixir Structs
```

### Expression Engine

The Expression engine uses NimbleParsec to parse and match step text against step definitions. It supports:

- Cucumber expressions with parameter types (`{string}`, `{int}`, `{float}`, `{word}`, `{atom}`)
- Optional parameters (`{int?}`)
- Alternation (`(click|tap)`)
- Escape sequences (`\{`, `\}`)
- Parameter conversion (string to typed values)

```elixir
defmodule Cucumber.Expression do
  # Compiles a cucumber expression into a matchable AST
  def compile(pattern) do
    # Parses pattern using NimbleParsec
    # Returns list of AST nodes with embedded parsers
  end

  # Matches text against a compiled expression
  def match(text, compiled) do
    # Uses recursive binary pattern matching
    # Returns {:match, args} or :no_match
  end
end
```

### Compiler

The compiler generates ExUnit test modules from discovered features:

```elixir
Compiler.compile_features!()
  ├── For each feature file:
  │   ├── Generates a test module
  │   ├── Creates setup from Background
  │   ├── Creates test cases from Scenarios
  │   └── Adds appropriate tags
  └── Compiles modules into memory
```

### Runtime

The runtime executes steps during test runs:

```elixir
Runtime.execute_step(context, step, step_registry)
  ├── Finds matching step definition
  ├── Prepares context with args, datatables, docstrings
  ├── Executes step function
  └── Processes return value
```

### StepDefinition Macro

The StepDefinition module provides the DSL for defining steps:

```elixir
defmodule MySteps do
  use Cucumber.StepDefinition

  step "pattern", context do
    # implementation
  end
end
```

## Execution Flow

1. **Discovery Phase** (at compile time)
   - `Cucumber.compile_features!()` is called in test_helper.exs
   - Discovery system finds all features and step definitions
   - Step registry is built with pattern → module mappings

2. **Compilation Phase**
   - For each feature, a test module is generated
   - Background steps become setup blocks
   - Scenarios become test cases
   - Tags are added for filtering

3. **Execution Phase** (at runtime)
   - ExUnit runs the generated test modules
   - Each test executes its steps via Runtime
   - Context is passed between steps
   - Errors are reported with helpful messages

## Data Flow

```
Feature File → Parser → AST
                          ↓
Step Files → Discovery → Registry
                          ↓
                      Compiler → Test Modules
                                      ↓
                                  ExUnit → Results
```

## Key Design Decisions

### Auto-Discovery
- Features and steps are automatically discovered
- No need to explicitly wire features to test modules
- Follows Ruby Cucumber's convention-over-configuration approach

### ExUnit Integration
- Generated tests are standard ExUnit test modules
- Full support for ExUnit features (tags, setup, async)
- Works with existing test tooling

### Runtime Compilation
- Tests are generated at runtime when `mix test` runs
- Allows for dynamic test generation
- No generated files to manage

### Context Management
- ExUnit context is used directly
- Background steps modify context in setup
- Each step can read and modify context

## Error Handling

Cucumber provides enhanced error messages with rich context:

1. **Undefined Steps**: Shows the exact step text with clickable file:line references and suggests implementation
2. **Step Failures**: Displays comprehensive error information including:
   - The failing step text with proper formatting
   - Clickable file:line reference to the scenario location (e.g., `test/features/example.feature:25`)
   - Visual step execution history with ✓ for passed and ✗ for failed steps
   - Formatted assertion errors extracted from ExUnit
   - Properly indented HTML output for PhoenixTest errors
   - Full stack traces for debugging
3. **Duplicate Steps**: Detected at load time with file/line information

The StepError module handles all error formatting, ensuring consistent and helpful error messages throughout the framework.

## Extensibility

The architecture supports several extension points:

1. **Custom Parameter Types**: Add new parameter types to Expression
2. **Custom Formatters**: Create custom output formats
3. **Hooks**: Before/after scenario hooks (via ExUnit setup/teardown)
4. **Step Libraries**: Create reusable step definition modules