# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Cucumber implementation for Elixir, providing a behavior-driven development (BDD) testing framework that uses Gherkin syntax to write executable specifications in natural language. It bridges the gap between technical and non-technical stakeholders by allowing tests to be written in plain language while being executed as code.

## Key Features

- Auto-discovery of feature files and step definitions
- Runtime test generation (no explicit test modules needed)
- Full ExUnit integration with tagging support
- Rich error messages with step suggestions

## Memory

- do not use co-author for claude in commit messages

## Commands

### Building and Running

```bash
# Compile the project
mix compile

# Run all tests
mix test

# Run a specific test file
mix test test/cucumber_test.exs

# Run a specific test that matches a pattern
mix test --only name_of_test

# Run all tests with detailed output
mix test --trace
```

### Development Workflow

```bash
# Format code
mix format

# Check code for issues
mix credo

# Generate documentation
mix docs

# Build the package locally (without publishing)
mix hex.build

# Publish package to Hex.pm (manually)
mix hex.publish

# Create a Git tag manually after publishing
git tag v0.1.0
git push origin v0.1.0

# OR use the automated release script (recommended)
./scripts/release.sh 0.1.0
```

## Architecture

This Cucumber implementation consists of several key components:

1. **Discovery System** (`lib/cucumber/discovery.ex`) - Auto-discovers features and steps
   - Scans for feature files based on patterns
   - Loads step definition modules
   - Builds a registry of step patterns

2. **Gherkin Parser** (`lib/gherkin.ex`) - Parses Gherkin syntax from `.feature` files
   - Features (with descriptions and tags)
   - Backgrounds (setup steps common to all scenarios)
   - Scenarios (with steps and tags)
   - Steps (with keywords, text, docstrings, and datatables)

3. **Compiler** (`lib/cucumber/compiler.ex`) - Generates ExUnit test modules
   - Creates one test module per feature file
   - Converts backgrounds to setup blocks
   - Converts scenarios to test cases
   - Adds appropriate tags for filtering

4. **Runtime** (`lib/cucumber/runtime.ex`) - Executes steps during tests
   - Finds matching step definitions
   - Manages context between steps
   - Handles datatables and docstrings
   - Processes step return values

5. **Step Definition** (`lib/cucumber/step_definition.ex`) - DSL for defining steps
   - `step` macro for defining step implementations
   - Automatic parameter extraction
   - Context management

6. **Error Handling** (`lib/cucumber/step_error.ex`) - Provides useful error messages
   - Detailed error reports when steps fail
   - Suggestions for missing step definitions

## Feature Files

Feature files follow the Gherkin syntax and should be placed in the `test/features/` directory with a `.feature` extension.

Example:
```gherkin
Feature: User Authentication

Background:
  Given the application is running

Scenario: User signs in with valid credentials
  Given I am on the sign in page
  When I enter "user@example.com" as my email
  And I enter "password123" as my password
  And I click the "Sign In" button
  Then I should be redirected to the dashboard
  And I should see "Welcome back" message
```

## Step Definitions

Step definitions connect Gherkin steps to code and are defined using the `step` macro in separate modules.

Example:
```elixir
# test/features/step_definitions/authentication_steps.exs
defmodule AuthenticationSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions
  
  step "I am on the sign in page", context do
    # Navigate to sign in page
    Map.put(context, :current_page, :sign_in)
  end
  
  step "I enter {string} as my email", %{args: [email]} = context do
    # Code to enter email
    Map.put(context, :email, email)
  end

  # More step definitions...
end
```

Step definitions are automatically discovered - no need to explicitly wire them to features.

## Return Value Patterns

Step definitions must return one of the following values (matching ExUnit's setup behavior):

1. `:ok` - Keeps the context unchanged
2. A map - Merged into the existing context
3. A keyword list - Merged into the existing context
4. `{:ok, map_or_keyword_list}` - Merged into the existing context
5. `{:error, reason}` - Fails the step with the given reason

## Advanced Features

- **Auto-discovery**: Features and steps are automatically found
- **Tagged tests**: Filter scenarios by tags using ExUnit's tag system
- **Background steps**: Common setup steps become ExUnit setup blocks
- **Data tables**: Tabular data with headers, rows, and map access
- **Docstrings**: Multi-line text in feature files
- **Context management**: ExUnit context used for sharing state

## Documentation Guidelines

### Elixir Documentation Best Practices

1. Use proper indentation for code examples (not triple backticks):

   ```elixir
   # INCORRECT - Do not use triple backticks in @doc
   @doc """
   ## Examples

   ```elixir
   Enum.map([1, 2, 3], fn x -> x * 2 end)
   ```
   """
   
   # CORRECT - Use indentation instead
   @doc """
   ## Examples

       Enum.map([1, 2, 3], fn x -> x * 2 end)
       # => [2, 4, 6]
   """
   ```

2. Start function documentation with a single-line summary followed by a blank line

3. Use proper Markdown sections with two hash marks (`##`)

4. Include examples for all public functions

5. Document all type specifications with `@type` to avoid documentation warnings

### Hex Package Requirements

The package configuration in `mix.exs` must include:

- `name` - The package display name
- `description` - A concise description of the package
- `version` - Following semantic versioning
- `source_url` - Link to GitHub repository
- `package` configuration with:
  - `licenses` - Using SPDX identifiers
  - `links` - Links to repository and other resources
  - `files` - List of files to include in the package

Files that should be maintained:

- README.md - With installation and usage instructions
- LICENSE - Specifying the package license
- CHANGELOG.md - Recording version changes