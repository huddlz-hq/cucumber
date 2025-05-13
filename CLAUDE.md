# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Cucumber implementation for Elixir, providing a behavior-driven development (BDD) testing framework that uses Gherkin syntax to write executable specifications in natural language. It bridges the gap between technical and non-technical stakeholders by allowing tests to be written in plain language while being executed as code.

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
```

## Architecture

This Cucumber implementation consists of several key components:

1. **Gherkin Parser** (`lib/gherkin.ex`) - Parses Gherkin syntax from `.feature` files into Elixir structs. Handles:
   - Features (with descriptions and tags)
   - Backgrounds (setup steps common to all scenarios in a feature)
   - Scenarios (with steps and tags)
   - Steps (with keywords, text, docstrings, and datatables)

2. **Cucumber Module** (`lib/cucumber.ex`) - Provides macros for test integration:
   - `use Cucumber` - Sets up a test module to run a specific feature file
   - `defstep` - Defines step implementations that match steps in the feature files
   - Pattern matching to connect steps to code
   - Context management to share state between steps

3. **Parameter Handling** (`lib/cucumber/expression.ex`) - Handles parameter extraction from steps
   - Supports string, integer, float, and word parameters
   - Manages datatable and docstring parameters

4. **Error Handling** (`lib/cucumber/step_error.ex`) - Provides useful error messages
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

Step definitions connect Gherkin steps to code and are defined using the `defstep` macro.

Example:
```elixir
defmodule UserAuthenticationTest do
  use Cucumber, feature: "user_authentication.feature"
  
  defstep "I am on the sign in page", context do
    # Navigate to sign in page
    Map.put(context, :current_page, :sign_in)
  end
  
  defstep "I enter {string} as my email", context do
    email = List.first(context.args)
    # Code to enter email
    Map.put(context, :email, email)
  end

  # More step definitions...
end
```

## Return Value Patterns

Step definitions can return values in several ways:

1. `:ok` - For steps that perform actions but don't update context
2. A map - To directly replace the context
3. `{:ok, map}` - To merge new values into the context
4. `{:error, reason}` - To indicate a step failure with a reason

## Advanced Features

- **Tagged tests**: Filter scenarios by tags
- **Background steps**: Common setup steps
- **Data tables**: Tabular data in feature files
- **Docstrings**: Multi-line text in feature files
- **Context management**: Sharing state between steps