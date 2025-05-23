# Changelog

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
