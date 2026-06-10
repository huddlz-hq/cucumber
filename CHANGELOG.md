# Changelog

## Unreleased

### Bug Fixes

- **Ambiguous steps are now detected** (#20). A step whose text matches more than one step definition previously executed an arbitrary first match and passed silently. Step resolution now collects all matches and raises `Cucumber.AmbiguousStepError` listing every matching pattern with its definition site (`file:line`), failing the scenario. Ambiguity is detected per step text at runtime; the discovery-time exact-duplicate check is unchanged.

### Improvements

- **Step failure stack traces point at the feature file** (#22). The first stack frame of a failing (or undefined, or ambiguous) step now references the feature file and the failing step's line; the step definition's own frame follows, and internal `Cucumber.Runtime` frames are filtered from the trace.
- **Single step-matching path.** Step dispatch now happens entirely in `Cucumber.Runtime` via the step registry; the generated per-module `step/2` dispatcher (which re-ran its own first-match loop) has been removed. **Breaking:** code calling `MySteps.step(context, text)` directly should go through `Cucumber.Runtime.execute_step/3` instead.
- **Step registry keys are now `{:expression, source}` tuples** (was bare pattern strings), making room for regex step definitions (#24). **Breaking** for code reading `DiscoveryResult.step_registry` directly.
- Generated feature modules no longer embed a full copy of the step registry and hook list in their AST; both now live in `:persistent_term` under per-compilation keys (also future-proof for `mix test.watch` staleness).

- **Descriptions under any section header now parse** (#17). Standard Gherkin allows free-form description text after `Background:`, `Scenario:`, `Scenario Outline:`, and `Examples:` headers; previously such lines caused a parse error that made the whole feature file unusable. Descriptions are now captured on the corresponding structs (`description` field, default `""`), and the feature-level description — previously discarded — is captured on `Gherkin.Feature.description`. Descriptions never affect execution.
- **Parser no longer hangs on a feature ending in a description.** A latent zero-width repeat in the description combinator could loop forever at end of input (e.g. a feature whose last line is description text, or a scenario with no steps at EOF).

### New Features

- **Regular expression step definitions** (#24). The `step` macro accepts `~r//` regexes alongside cucumber expression strings. A regex must match the entire step text (full-text matching is enforced whether or not the author anchors); capture groups arrive in `context.args` in order as strings (no type conversion), with `nil` for unmatched optional groups. Regex definitions participate in ambiguity detection together with expressions, and exact-duplicate regexes are rejected at discovery. Registry keys for regex patterns are `{:regex, {source, opts}}`.
- **The Rule keyword** (#19). Rules group related scenarios under a feature; each rule can carry its own description, tags, and `Background:`. Rule-background steps run after the feature background for every scenario in the rule (spec order: feature background → rule background → scenario steps), rule tags are inherited by the rule's scenarios (so they participate in ExUnit tag filtering and tagged hooks), and `Example:` is accepted as a synonym for `Scenario:`. Parsed rules live on the new `Gherkin.Feature.rules` field as `Gherkin.Rule` structs; test names for scenarios inside a rule are prefixed with the rule name so identically-named scenarios in different rules don't collide.
- **Backtick docstrings and media types** (#18). Docstrings can be delimited with ``` ``` ``` as an alternative to `"""`; the closing delimiter must match the opening one, and either delimiter style is plain content inside the other. An optional media type may follow the opening delimiter (e.g. ` ```json `) and is available as `Gherkin.Step.docstring_media_type` and `context.docstring_media_type` in step definitions. `context.docstring` remains a plain string.

### Improvements

- **Behavior test harness.** New `Cucumber.BehaviorCase` test-case template (test-only, in `test/support/`) runs a Gherkin source against explicit step/hook modules through the real compile pipeline in a nested ExUnit run and reports the outcome — making failing, undefined, and otherwise broken scenarios assertable in the test suite. Behavior fixtures from the [Cucumber Compatibility Kit](https://github.com/cucumber/compatibility-kit) are vendored under `test/fixtures/cck/` (MIT) and backed by behavior tests asserting reference outcomes.
- `Cucumber.Compiler.compile_feature!/3` is now public (`@doc false`) so test harnesses can compile a single parsed feature against an explicit step registry.
- Removed an unreachable clause in `Cucumber.Runtime` exception formatting that failed `mix compile --warnings-as-errors` under Elixir 1.20's type checker.
- **Bumped Credo** to 1.7.19 — 1.7.16 crashed on Elixir 1.20's new sigil token format, breaking `mix precommit`.

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
