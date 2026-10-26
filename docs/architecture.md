# Cucumber Architecture

This document provides an overview of the Cucumber implementation architecture, explaining the core components and how they interact.

## Core Components

```
Cucumber
  ├── Discovery (Feature/Step/Hook Finding)
  ├── StepRegistry (Step Definitions & Matching)
  ├── Gherkin (Parser: .feature and .feature.md)
  ├── Gherkin.Pickles (Scenario Expansion)
  ├── Expression (Parameter Matching)
  ├── Compiler (Test Generation)
  ├── Runtime (Scenario Lifecycle & Step Execution)
  ├── RunCoordinator (Run-Wide State)
  ├── Messages (Cucumber Messages NDJSON)
  └── StepError (Error Reporting)
```

### Discovery System

The discovery system automatically finds and loads feature files, step definitions, hooks, and custom parameter types:

```elixir
Discovery.discover()
  ├── Scans for features (test/features/**/*.feature and **/*.feature.md)
  ├── Loads support files (test/features/support/**/*.exs — hooks, parameter types)
  ├── Loads step definitions (test/features/step_definitions/**/*.exs)
  └── Returns: features, step registry, hooks
```

### Step Registry

`Cucumber.StepRegistry` is the complete set of step definitions and parameter types for a run, and the one place step text is matched against them. Discovery builds it from the loaded step and parameter-type modules; building merges the parameter types, compiles every pattern once, rejects duplicate definitions and types, drops (with a warning) definitions that use undefined parameter types, and orders definitions by file and line.

```elixir
StepRegistry.new(step_modules, parameter_type_modules)
StepRegistry.match(registry, step_text)
  # => {:ok, definition, args} | :undefined | {:ambiguous, [{definition, args}]}
```

Each scenario is matched once, into a test case (`lib/cucumber/test_case.ex`): its scenario hooks selected by tag and the step definitions every step matches, in run order. The runtime executes the test case, retries reuse it, and the Cucumber Messages emitter builds `testCase.testSteps` from it, so hook selection and matching happen in exactly one place. A step's arguments are converted only when the step runs, on every attempt: parameter type transforms are user code, and may depend on what earlier hooks and steps set up.

### Gherkin Parser

The Gherkin parser uses NimbleParsec to parse `.feature` files into Elixir structs. A separate line-scanner parser (`Gherkin.Markdown`) parses `.feature.md` ([Markdown with Gherkin](https://github.com/cucumber/gherkin/blob/main/MARKDOWN_WITH_GHERKIN.md)) files into the same structs. Together they handle:

- Feature declarations with descriptions and tags
- Rules with their own backgrounds, tags, and descriptions
- Scenario outlines with Examples tables
- Backgrounds
- Steps (Given, When, Then, And, But, *)
- Data tables and doc strings (with media types)
- Tags at feature, rule, scenario, and examples levels

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
- Custom parameter types defined with `Cucumber.ParameterTypes` (regexp + transform)
- Optional parameters (`{int?}`)
- Optional text (`(s)` for pluralization)
- Alternation (`click/tap`)
- Escape sequences (`\{`, `\}`, `\(`, `\)`, `\/`, `\\`)
- Parameter conversion (string to typed values)

Step definitions can also use plain regular expressions (`step ~r/.../`), which participate in the same single matching path in `Cucumber.StepRegistry` — so ambiguity between a regex and a cucumber expression is detected like any other ambiguity and raises `Cucumber.AmbiguousStepError`.

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

Features are first expanded into *pickles* — one concrete, runnable scenario per outline row, with rule backgrounds and tags folded in — by `Gherkin.Pickles`. The compiler then generates ExUnit test modules from them:

```elixir
Compiler.compile_features!()
  ├── Expands features into pickles (outlines × example rows, rules flattened)
  ├── For each feature file:
  │   ├── Generates a test module
  │   ├── Creates one ExUnit test per pickle
  │   └── Adds appropriate tags
  └── Compiles modules into memory
```

### Runtime

Each generated test body is a single call into the runtime, which owns the whole scenario lifecycle inside the test process — before hooks, background steps, scenario steps, and after hooks (which run on pass and on fail):

```elixir
Runtime.run_scenario(context, ...)
  ├── Builds the scenario's test case once (Cucumber.TestCase): scenario hooks
  │   selected by tag, every step matched to its step definitions
  │   (0 → undefined, >1 → ambiguous), test steps numbered in run order
  ├── Runs before-scenario hooks (and lazily before_all, once per run)
  ├── Executes background steps, then scenario steps:
  │   ├── Uses the step's match from the test case
  │   ├── Converts its args (running parameter type transforms)
  │   ├── Prepares context with args, datatables, docstrings
  │   ├── Brackets it with before_step/after_step hooks
  │   └── Processes the return value (incl. pending/skipped, retry)
  └── Runs after-scenario hooks in reverse order
```

### RunCoordinator

A GenServer holding run-wide state: `before_all` once-guards and their shared context, attachments, retry bookkeeping, and the run's Cucumber Messages recorder. It serializes run-level effects so `@async` features stay safe.

### Messages

With `config :cucumber, messages: "path.ndjson"`, the run emits the standard [Cucumber Messages](https://github.com/cucumber/messages) stream — source, gherkinDocument, pickles, and testCase/testStep lifecycle events — as NDJSON, verified against the reference implementation by the Cucumber Compatibility Kit approval suite in this repo.

The stream is built by a pure message recorder (`lib/cucumber/messages/recorder.ex`): run-time events go in (a test case opened, an attempt started, a step finished, a run hook finished, the run ended) and envelopes come out. It owns message ids, the status of steps that never ran, closing crashed test cases as UNKNOWN, and NDJSON encoding, and is tested by feeding it event sequences. `RunCoordinator` holds it and feeds it events in order; `Messages.Emitter` builds the run's static envelopes and turns the runner's progress into events.

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
   - The step registry is built from step definition and parameter type modules

2. **Compilation Phase**
   - Features are expanded into pickles (outline rows, rule flattening)
   - For each feature, a test module is generated with one test per pickle
   - Tags are added for filtering

3. **Execution Phase** (at runtime)
   - ExUnit runs the generated test modules
   - Each test runs its full scenario lifecycle (hooks, background, steps) via Runtime
   - Context is passed between steps
   - Errors are reported with helpful messages

## Data Flow

```
Feature File → Parser → AST
                          ↓
Step Files → Discovery → StepRegistry
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
- Hooks and background steps build up the context before scenario steps run — all inside the test process
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

1. **Custom Parameter Types**: Define your own `{type}` parameters with `Cucumber.ParameterTypes`
2. **Cucumber Messages**: Consume the NDJSON stream with any standards-based report tooling
3. **Hooks**: Run-level, scenario, and step hooks with tags and names (via `Cucumber.Hooks`)
4. **Step Libraries**: Create reusable step definition modules