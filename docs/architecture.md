# Cucumber Architecture

This document provides an overview of the Cucumber implementation architecture, explaining the core components and how they interact.

## Core Components

```
Cucumber
  ├── Gherkin (Parser)
  ├── Expression (Parameter Matching)
  ├── Runner (Test Execution)
  └── Formatter (Output)
```

### Gherkin Parser

The Gherkin parser is responsible for parsing `.feature` files into a structured format that can be executed. It handles the syntax of Gherkin, including:

- Feature declarations
- Scenario outlines
- Backgrounds
- Steps (Given, When, Then)
- Tables and doc strings
- Tags

The parser produces an Abstract Syntax Tree (AST) that represents the structure of the feature file.

```elixir
# Simplified representation of the Gherkin parser flow
Feature File (Text) → Lexer → Tokens → Parser → AST
```

### Expression Engine

The Expression engine is responsible for matching step text against step definitions. It supports:

- Regular expressions
- Cucumber expressions (a simplified syntax with parameter types)
- Parameter conversion (string to typed values)

```elixir
defmodule Cucumber.Expression do
  # Converts a cucumber expression into a regex and parameter converters
  def compile(pattern) do
    # Transforms {string}, {int}, etc. into regex patterns
    # Returns {regex, converters}
  end

  # Matches text against a compiled expression
  def match(text, {regex, converters}) do
    # Returns {:match, args} or :no_match
  end
end
```

### Runner

The Runner is responsible for executing the parsed features against step definitions. It:

1. Loads feature files
2. Finds matching step definitions
3. Executes steps in order
4. Manages test context between steps
5. Handles errors and reporting

```
Feature → Scenarios → Steps → Step Definitions → Execution
```

### Context Management

The context is a map that's passed between step definitions, allowing them to share state. The runner:

1. Creates an initial context
2. Passes it to each step
3. Collects the updated context
4. Passes the updated context to the next step

```elixir
# Example context flow
initial_context = %{feature_name: "Authentication"}
{:ok, updated_context} = execute_step(step1, initial_context)
{:ok, final_context} = execute_step(step2, updated_context)
```

## Integration with ExUnit

The Cucumber library integrates with ExUnit through:

1. Custom ExUnit case modules
2. Test module generation
3. Test callbacks (setup, teardown)

```elixir
# Simplified representation of ExUnit integration
defmodule MyTest do
  use Cucumber, feature: "my.feature"
  
  # Step definitions become test functions
  # Scenarios become test cases
end
```

## Macro System

Cucumber uses Elixir's macro system extensively to provide a clean DSL:

```elixir
defmodule MyTest do
  use Cucumber, feature: "authentication.feature"
  
  # Macros transform these into functions
  defstep "I am on the login page", _context do
    # Implementation
    :ok
  end
end
```

At compile time, these macros:

1. Read the feature file
2. Generate ExUnit test cases
3. Register step definitions
4. Set up test callbacks

## Extension Points

The architecture provides several extension points:

1. **Custom Parameter Types**: Extend the Expression engine with new types
2. **Formatters**: Create custom output formats
3. **Hooks**: Add before/after hooks at different levels
4. **Tags**: Filter and customize execution based on tags

## Implementation Details

### Optimizations

- **Step Definition Registry**: Fast lookup of step definitions
- **Pattern Compilation**: Expressions are compiled once and reused
- **Lazy Loading**: Feature files are parsed on demand

### Error Handling

When a step fails, the system:

1. Captures the error information
2. Adds context about the feature and scenario
3. Reports detailed failure information
4. Stops execution of the current scenario
5. Continues with the next scenario

## Execution Flow

```
1. Feature loading
   ├── Parse feature files
   └── Build execution plan

2. Test compilation
   ├── Generate ExUnit tests
   └── Register step definitions

3. Test execution
   ├── Setup test environment
   ├── Execute steps
   │   ├── Find matching step definition
   │   ├── Apply parameter conversions
   │   ├── Execute step function
   │   └── Manage context between steps
   └── Report results
```

## Code Structure

```
lib/
├── cucumber.ex             # Main module and API
├── gherkin.ex              # Feature file parser
├── cucumber/
    ├── expression.ex       # Step matching engine
    ├── runner.ex           # Test execution
    ├── formatter.ex        # Output formatting
    ├── step_definition.ex  # Step definition handling
    └── hooks.ex            # Before/after hooks
```

## Runtime Behavior

1. The `use Cucumber` macro transforms the module at compile time
2. ExUnit runs the generated test cases
3. Each scenario becomes a test case
4. Each step invocation:
   - Finds the matching step definition
   - Extracts parameters
   - Runs the step function
   - Manages the context
5. Results are reported through ExUnit's reporting system

This architecture provides a solid foundation that balances simplicity of use with flexibility for extension.