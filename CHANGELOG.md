# Changelog

## Unreleased

This release completes the Cucumber Compatibility Kit roadmap (#17–#29). Cucumber for Elixir is now CCK compliant: the official [CCK](https://github.com/cucumber/compatibility-kit) runs as an approval suite in this repo, comparing the Cucumber Messages we emit against the reference implementation's output. Full documentation for every feature below lives in the [guides](https://hexdocs.pm/cucumber).

### Breaking and behavior changes

- **The scenario lifecycle now runs entirely inside the test body.** Before hooks, background steps, scenario steps, and after hooks all run in the test process — no longer split across ExUnit `setup` and `on_exit`. A failing background step is reported as a normal in-test failure (previously a setup failure), and after hooks run on pass and fail alike.
- **A scenario with no steps of its own no longer runs the background** (matches the reference compiler; previously background steps ran anyway).
- The compiler now generates one ExUnit test per pickle. `Cucumber.Compiler.expand_feature/1` and `expand_all_scenarios/1` are removed — use `Gherkin.Pickles.compile/2` — and the dormant `Gherkin.Scenario.rule` field is gone.
- The generated per-module `step/2` dispatcher is removed; dispatch happens once, in `Cucumber.Runtime`, via the step registry. Registry keys are now `{:expression, source}` / `{:regex, {source, opts}}` tuples (**breaking** for code reading `DiscoveryResult.step_registry` directly).
- Hook internals changed shape: hook tuples are now `{type, tag, name, {module, function}}`, `Cucumber.Hooks.run_before_hooks`/`run_after_hooks` take an optional around-callback and return `{:error, reason, hook_name}` on failure, and `Cucumber.RunCoordinator.record_attachment/2` takes a message reference.
- A `.feature` and `.feature.md` file that would generate the same test module now fail compilation with a clear error (previously the second silently redefined the first).

### New Features

- **Cucumber Messages** (#28). Setting `config :cucumber, messages: "cucumber-messages.ndjson"` writes a complete [Cucumber Messages](https://github.com/cucumber/messages) NDJSON stream for the run — sources, Gherkin documents, pickles, step definitions, hooks, and the full test-case/test-step lifecycle with statuses, durations, retry attempts, and attachments. Without the config nothing is emitted and the runtime path is unchanged. Known deltas from the reference stream are documented in `Cucumber.Messages`.
- **Markdown feature files** (#29). `*.feature.md` files ([Markdown with Gherkin](https://github.com/cucumber/gherkin/blob/main/MARKDOWN_WITH_GHERKIN.md)) are discovered alongside `*.feature`: keyword headings, bullet-list steps, fenced-code docstrings, indented tables, code-span tags — everything else is prose. Error locations and message locations reference the Markdown source lines.
- **Retry** (#26). Retry failing scenarios with `config :cucumber, retry: n`, overridable per scenario/examples/outline/rule/feature with `@retry-n` tags (most specific wins; `@retry-0` exempts). Each attempt re-runs the full lifecycle with a fresh context (`context.retry_attempt`); undefined, ambiguous, and pending scenarios never retry.
- **Attachments** (#25). `Cucumber.attach/4` (plus `Cucumber.log/2` and `Cucumber.link/2`) attaches data to the current step or hook from any step definition or hook. Failing steps list their scenario's attachments; with messages enabled each attachment is emitted as an `attachment` envelope.
- **Run-level, step-level, and named hooks** (#27). `before_all`/`after_all` run once per test run (lazily, `@async`-safe, with the `before_all` context merged into every scenario); `before_step`/`after_step` bracket every step, with `after_step` seeing the step's status; any hook takes `name:`, which shows up in failure output and lifts the one-hook-per-kind-per-module limit.
- **Pending and skipped step results** (#21). Steps and before hooks can return `:pending`/`{:pending, message}` — halts the scenario and fails it with `Cucumber.PendingStepError` — or `:skipped`/`{:skipped, reason}` — halts without failing (ExUnit has no runtime-skip API, so the summary counts it as passed). After hooks still run in both cases.
- **Custom parameter types** (#23). Register domain types in support files with `use Cucumber.ParameterTypes` and `parameter_type :flight, regexp: ~r/.../, transform: fn ... end`, then use `{flight}` in step patterns like any built-in.
- **Regular expression step definitions** (#24). The `step` macro accepts `~r//` regexes alongside cucumber expressions; the regex must match the entire step text, and captures arrive in `context.args` as strings.
- **The Rule keyword** (#19). Rules group scenarios with their own description, tags, and `Background:` (run order: feature background → rule background → steps); `Example:` is accepted as a synonym for `Scenario:`.
- **Backtick docstrings and media types** (#18). ` ``` ` works as an alternative docstring delimiter, and an optional media type after the opening delimiter (e.g. ` ```json `) is available as `context.docstring_media_type`.
- **Section descriptions** (#17). Free-form description text after `Background:`, `Scenario:`, `Scenario Outline:`, and `Examples:` headers now parses (previously a parse error) and is captured on the structs, as is the feature-level description.

### Bug Fixes

- **Ambiguous steps are now detected** (#20). A step matching more than one definition previously executed an arbitrary first match and passed silently; it now raises `Cucumber.AmbiguousStepError` listing every matching pattern with its `file:line`.
- **Step failure stack traces point at the feature file** (#22). The first frame of a failing step's trace is now `feature_file:step_line`, followed by the step definition; internal runtime frames are filtered out.
- The parser no longer hangs on a feature file that ends in description text.
- `Cucumber.Hooks.collect_hooks/1` now finds hook modules compiled into the application but not yet loaded (previously they were silently dropped).
- `context.docstring_media_type` now substitutes scenario outline placeholders, like the docstring content does.

### Improvements

- The emitted `gherkinDocument` carries source comments, per-tag source lines, and docstring delimiter styles (new parser fields; published struct shapes unchanged), and step statuses follow CCK semantics — e.g. unexecuted steps after a failure report `UNDEFINED`/`AMBIGUOUS` when they'd have been, rather than blanket `SKIPPED`.
- Generated feature modules no longer embed the step registry and hook list in their AST; both live in `:persistent_term` under per-compilation keys.
- New `Cucumber.BehaviorCase` test harness (repo-internal) makes failing, pending, undefined, and ambiguous scenarios assertable in the test suite, backed by vendored CCK fixtures.
- Bumped Credo to 1.7.19 for Elixir 1.20 compatibility.

## v0.9.1 (2026-05-12)

### Bug Fixes

- **Gherkin parser: comment lines no longer drop scenarios.** Previously, a `# …` line between Background and the first Scenario, between scenarios, between steps, or between a tag and the following `Scenario:` / `Examples:` keyword caused **scenarios in the file to be silently dropped**, with no error raised. The parser now recognizes `#`-prefixed lines as skippable wherever blank lines are valid (including interspersed within tag groups). Comments inside docstrings remain content (unchanged); comments inside data tables and trailing inline comments are still not supported.
- **Parser no longer silently truncates on partial parses.** `Gherkin.Parser.parse/1` used to return a partial feature when the parser stopped before end of file — masking exactly the kind of bug above. It now raises `Gherkin.ParseError` if any non-whitespace content remains unconsumed.

### Improvements

- **Empty-feature warning.** `Cucumber.Compiler` now emits `IO.warn` if a feature file parses to zero scenarios — a defensive net for parser regressions of the shape above. The warning fires when `Cucumber.compile_features!/1` runs (typically from `test/test_helper.exs` at `mix test` time). **Heads-up for `mix test --warnings-as-errors`:** projects that check in scaffold `.feature` files with no scenarios will trip this and abort the test suite until at least one scenario is added. (`mix compile --warnings-as-errors` is unaffected — the warning is not emitted during `.ex` compilation.)

## v0.9.0 (2026-02-10)

### New Features

- **Igniter Installer**: Added `mix cucumber.install` task for automated project setup
  - Adds `Cucumber.compile_features!()` to `test/test_helper.exs`
  - Configures `test_ignore_filters` in `mix.exs`

### Improvements

- **Expression Caching**: Compiled expressions are now cached with `:persistent_term` for better performance
- **Elixir 1.20 Compatibility**: Pin operators in bitstring size specifiers for forward compatibility
- **CI Pipeline**: Added GitHub Actions workflow with Elixir 1.19/OTP 28 and Elixir 1.20-rc allow-failure job
- **Precommit Alias**: `mix precommit` now includes `credo --strict`
- **Error Handling**: Improved discovery error propagation — syntax errors in step files and hooks are no longer silenced
- **Bumped Credo** to 1.7.16

## v0.8.0 (2025-11-29)

### Breaking Changes

- **Official Cucumber Expression Syntax**: Updated to match the official Cucumber Expression syntax
  - `(text)` now means **optional text** (was alternation with `|`)
  - `word1/word2` is the new **alternation** syntax (replaces `(a|b)`)
  - New escape sequences: `\(`, `\)`, `\/`, `\\`
  - Example: `"I have {int} cucumber(s)"` matches both singular and plural
  - Example: `"I click/tap the button"` matches either verb

### Migration from v0.7.0

If you were using the old alternation syntax, update your step definitions:

```elixir
# Old (v0.7.0)
step "I (click|tap) the button", context do

# New (v0.8.0)
step "I click/tap the button", context do
```

## v0.7.0 (2025-11-26)

### New Features

- **NimbleParsec Gherkin Parser**: Replaced line-by-line regex parser with compiled NimbleParsec parser
  - Better error messages with line and column information
  - Foundation for future i18n support
  - Improved maintainability with bottom-up combinator composition

## v0.6.0 (2025-11-26)

### New Features

- **Scenario Outline Support**: Run the same scenario with different data sets
  - Use `<placeholders>` in step text with values from `Examples:` tables
  - Each Examples row generates a separate test case
  - Named Examples blocks for better organization (e.g., `Examples: valid credentials`)
  - Tagged Examples blocks for selective test execution
  - Placeholders work in doc strings and data tables
  - Full tag inheritance from Feature → Scenario Outline → Examples

### Documentation

- Added comprehensive Scenario Outline documentation to feature files guide
- Examples for named and tagged Examples blocks
- Placeholder usage in doc strings and data tables

## v0.5.0 (2025-11-26)

### New Features

- **Expression Engine Rewrite**: Replaced regex-based expression parsing with NimbleParsec
  - Pure parser combinators and binary pattern matching (no regex)
  - Better foundation for future Gherkin parser improvements

- **Optional Parameters**: Use `{int?}` for optional matching
  - Returns the value if present, `nil` if absent
  - Example: `"I have {int?} items"` matches both "I have 5 items" and "I have items"

- **Alternation**: Use `(option1|option2)` for alternative text
  - Matches any option but does not capture
  - Example: `"I (click|tap) the button"` matches either verb

- **Escape Sequences**: Use `\{` and `\}` for literal braces
  - Example: `"I see \{placeholder\}"` matches "I see {placeholder}"

- **Atom Parameter Type**: Use `{atom}` to match and convert to atoms
  - Example: `"status is {atom}"` matches "status is pending" and returns `:pending`

### Breaking Changes

- **Compiled Expression Format**: `Expression.compile/1` now returns an AST list instead of `{Regex.t(), [function]}` tuple
  - The `match/2` function signature and return values are unchanged
  - Direct users of `compile/1` return value will need updates

## v0.4.2 (2025-11-25)

### Bug Fixes

- **Hook Execution Order**: Fixed timing issue where hooks were running after background steps
  - All hooks (global, feature-level, and scenario-specific) now execute in ExUnit's setup block
  - Hooks run before background steps, ensuring database connections are ready
  - Simplified architecture: hooks match against combined feature + scenario tags
  - Prevents database connection errors when background steps require database access

### Improvements

- **Descriptive Hook Function Names**: Hook functions now use readable names like `before_scenario_database` instead of numeric IDs
- **Duplicate Hook Detection**: Compile-time error when defining the same hook twice
- **Updated Dependencies**: mix_test_watch 1.4.0, credo, ex_doc

## v0.4.1 (2025-06-06)

### New Features

- **Enhanced Error Formatting**: Significantly improved error messages for better debugging experience
  - Added scenario line numbers to error messages with clickable file:line format (e.g., `test/features/example.feature:9`)
  - Display contextual information including feature file path and scenario name
  - Show step execution history with clear pass/fail indicators
  - Improved PhoenixTest HTML element formatting with proper indentation
  - Better assertion error extraction and formatting for readability
  - Preserve stack traces with reraise for comprehensive debugging

### Internal Improvements

- Added comprehensive test coverage for error formatting scenarios
- Added unit tests for StepError module covering all error cases
- Added tests for Runtime error handling and formatting

## v0.4.0 (2025-05-28)

### New Features

- **Hooks Support**: Added before/after scenario hooks for setup and teardown
  - Define hooks in `test/features/support/` files
  - Global hooks run for all scenarios
  - Tag-filtered hooks run only for matching scenarios (e.g., `@database`)
  - Hooks can modify test context
  - Support for async scenarios
  - Auto-discovery of support files

### Documentation

- Added comprehensive hooks documentation guide
- Updated README with hooks feature
- Added practical examples for database setup, authentication, and performance monitoring

### Examples

- Added database setup example showing selective setup with `@database` tag
- Demonstrates how to avoid unnecessary setup for tests that don't need it

## v0.3.1 (2025-05-28)

### New Features

- **Async Test Execution**: Added support for concurrent test execution using the `@async` tag
  - Features marked with `@async` run concurrently with other async tests
  - Improves test suite performance for independent features
  - Safe to use with Ecto SQL sandbox in shared mode
  - Comprehensive documentation added

### Documentation

- Updated README with async feature documentation
- Enhanced feature files guide with `@async` tag usage
- Added async examples to getting started guide

## v0.3.0 (2025-05-28)

### Complete Architecture Redesign

This release completely redesigns the Cucumber library to follow Ruby Cucumber conventions with auto-discovery of features and step definitions.

#### Breaking Changes

1. **Auto-Discovery Architecture**
   - Tests are now auto-discovered - no need for explicit test modules
   - Feature files must be in `test/features/`
   - Step definitions must be in `test/features/step_definitions/`
   - Support files can be in `test/features/support/`
   - Just call `Cucumber.compile_features!()` in `test_helper.exs`

2. **New Step Definition Syntax**
   - Use `step` macro instead of `defstep`
   - Step definitions now use `use Cucumber.StepDefinition`
   - No more `use Cucumber, feature: "..."`

3. **Simplified API**
   - Main module only exports `compile_features!/1`
   - Step definitions are registered automatically
   - Background steps become ExUnit setup blocks

#### New Features

1. **Ruby Cucumber Compatibility**
   - Directory structure matches Ruby Cucumber conventions
   - Configurable paths using glob patterns
   - One ExUnit test module generated per feature file

2. **Better Integration**
   - Seamless `mix test` integration
   - ExUnit tags work as expected
   - Standard ExUnit context for state management

#### Migration from v0.2.0

1. Move your test files:
   ```
   # Old structure
   test/my_feature_test.exs

   # New structure
   test/features/my_feature.feature
   test/features/step_definitions/my_steps.exs
   ```

2. Update step definitions:
   ```elixir
   # Old
   defmodule MyFeatureTest do
     use Cucumber, feature: "my_feature.feature"

     defstep "I do something", context do
       {:ok, context}
     end
   end

   # New
   defmodule MySteps do
     use Cucumber.StepDefinition

     step "I do something", context do
       {:ok, context}
     end
   end
   ```

3. Update test_helper.exs:
   ```elixir
   # Old
   ExUnit.start()

   # New
   ExUnit.start()
   Cucumber.compile_features!()
   ```

## v0.2.0 (2025-05-23)

 New Features

  1. Shared Steps Support (Major Feature)
    - Added Cucumber.SharedSteps module for creating reusable step definitions
    - Allows step definitions to be defined in separate modules and imported
    - Supports composition of step libraries across test files
    - Maintains proper error reporting with accurate line numbers
    - Full test coverage with integration tests

  Breaking Changes

  1. Step Return Value Handling (Aligns with ExUnit)
    - Maps now merge into context instead of replacing it
    - Removed support for nil return values
    - Removed catch-all for arbitrary return values - now raises clear errors
    - Added support for keyword list return values
    - Valid returns: :ok, map, keyword_list, {:ok, map_or_keyword_list}, {:error, reason}

  Improvements

  1. Code Quality
    - Eliminated major duplication in Gherkin parser (68 lines removed, 16% reduction)
    - Replaced all List.first(context.args) with idiomatic pattern matching
    - Refactored to meet Credo strict standards
    - Improved documentation and examples
  2. Developer Experience
    - Better error messages for invalid step return values
    - More idiomatic Elixir patterns throughout
    - Cleaner API that matches ExUnit conventions

  Infrastructure

  1. Release Automation
    - Added scripts/release.sh for automated releases
    - Improved release process documentation

  Migration Guide

  For v0.1.0 users upgrading to v0.2.0:

  1. Step return values:
    - Change nil returns to :ok
    - Ensure maps are being merged (not replaced) as expected
    - Remove any non-standard return values
  2. Pattern matching:
    - Update List.first(context.args) to %{args: [var]} = context

## v0.1.0 (2024-05-13)

* Initial release
* Core features:
  * Gherkin parser with Background, Scenario, Step support
  * Cucumber expressions with parameter types ({string}, {int}, {float}, {word})
  * Data tables and docstring support
  * Tag filtering
  * Context passing between steps
  * Detailed error reporting
