# Hooks

Cucumber for Elixir provides hooks that allow you to run code around the whole run (`before_all`/`after_all`), around each scenario (`before_scenario`/`after_scenario`), and around each step (`before_step`/`after_step`). This is useful for setup and teardown operations like database transactions, authentication, or any other cross-cutting concerns.

## Overview

Hooks are defined in support files placed in `test/features/support/` and are automatically discovered and executed at the appropriate times during test execution.

## Defining Hooks

To define hooks, create a module that uses `Cucumber.Hooks`:

```elixir
# test/features/support/database_support.exs
defmodule DatabaseSupport do
  use Cucumber.Hooks

  # Global hook - runs before every scenario
  before_scenario context do
    # Your setup code here
    {:ok, Map.put(context, :setup_done, true)}
  end

  # Tagged hook - only runs for scenarios with @database tag
  before_scenario "@database", context do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)

    if context.async do
      Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
    end

    {:ok, context}
  end

  # After hooks run in reverse order of definition
  after_scenario _context do
    # Cleanup code
    :ok
  end
end
```

## Hook Types

### Before Scenario Hooks

Run before each scenario:

```elixir
# Global before hook
before_scenario context do
  # Runs before every scenario
  {:ok, context}
end

# Tagged before hook
before_scenario "@slow", context do
  # Only runs for scenarios tagged with @slow
  {:ok, Map.put(context, :timeout, 30_000)}
end
```

### After Scenario Hooks

Run after each scenario:

```elixir
# Global after hook
after_scenario context do
  # Runs after every scenario
  :ok
end

# Tagged after hook
after_scenario "@api", context do
  # Only runs for scenarios tagged with @api
  # Clean up API state
  :ok
end
```

### Run-Level Hooks (BeforeAll/AfterAll)

`before_all` hooks run lazily, exactly once per test run, before the first
scenario that executes — serialized through a run coordinator, so they are
safe with `@async` features. Their accumulated context map is merged into
every scenario's context. If a `before_all` hook fails, the remaining
`before_all` hooks still run (to set up as much as possible for cleanup),
but every scenario in the run fails with the original error.

`after_all` hooks run once after the whole suite, in reverse definition
order, receiving the `before_all` context with the ExUnit suite summary
merged under `:suite_result`. A failing `after_all` hook fails the run; the
remaining `after_all` hooks still run.

Run-level hooks cannot be tagged (they don't belong to any scenario):

```elixir
before_all context do
  {:ok, server} = start_external_service()
  {:ok, Map.put(context, :service, server)}
end

after_all context do
  stop_external_service(context.service)
  :ok
end
```

### Step Hooks

`before_step` and `after_step` hooks bracket every step of matching
scenarios, including background steps. They receive the step's prepared
context — `:step` (the `Gherkin.Step` struct), `:args`, and any
`:datatable`/`:docstring`. `after_step` additionally sees `:step_status`
(`:passed`, `:failed`, `:pending`, or `:skipped`) and runs for failing
steps too.

A `{:error, reason}` from a `before_step` hook fails the scenario without
running the step body; `:skipped`/`:pending` signals from `before_step`
halt the scenario just like the step itself returning them. `after_step`
return values are ignored.

```elixir
before_step "@traced", context do
  IO.puts("→ #{context.step.keyword} #{context.step.text}")
  :ok
end

after_step "@traced", context do
  IO.puts("← #{context.step.text}: #{context.step_status}")
  :ok
end
```

### Named Hooks

Any hook can be given a `name:`, which appears in failure output. Names
also lift the one-hook-per-kind restriction, so a module can define any
number of distinctly-named hooks of the same kind:

```elixir
before_scenario context, name: "prepare database" do
  {:ok, context}
end

before_scenario "@admin", context, name: "sign in as admin" do
  {:ok, context}
end
```

## Return Values

Hooks support the same return values as step definitions:

- `:ok` - Keeps the context unchanged
- `{:ok, map}` - Merges the map into the context
- `%{} = map` - Merges the map into the context
- `{:error, reason}` - Fails the scenario before it starts (steps and after
  hooks don't run)
- `:skipped` or `{:skipped, reason}` (before hooks only) - Skips the whole
  scenario without failing it: remaining before hooks and all steps are
  skipped, after hooks still run
- `:pending` or `{:pending, message}` (before hooks only) - Like `:skipped`,
  but the scenario fails with `Cucumber.PendingStepError`

Return values from after hooks are ignored, so an after hook returning
`:skipped` only marks itself — subsequent after hooks still run.

## Hook Execution Order

1. `before_all` hooks run once, in definition order, before the first scenario
2. Before hooks run in the order they are defined
3. `before_step`/`after_step` hooks bracket each step (after-step in reverse order)
4. After hooks run in reverse order (last defined runs first)
5. `after_all` hooks run once, in reverse order, after the whole suite
6. Tagged hooks only run for scenarios with matching tags
7. Global hooks run for all scenarios

## Tag Inheritance

Feature-level tags are inherited by all scenarios in that feature:

```gherkin
@database
Feature: User Management
  # All scenarios inherit @database tag

Scenario: Create user
  # This scenario has @database tag
  Given a new user

@api
Scenario: API user creation
  # This scenario has both @database and @api tags
  Given an API request
```

## Context Variables

The context passed to hooks includes:

- `:scenario_name` - The name of the current scenario
- `:async` - Whether the feature is running in async mode
- `:step_history` - List of steps executed (empty in before hooks)
- Any data added by previous hooks or steps

## Practical Examples

### Database Setup

```elixir
defmodule DatabaseSupport do
  use Cucumber.Hooks

  before_scenario "@database", context do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)

    if context.async do
      Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
    end

    {:ok, context}
  end
end
```

### Authentication

```elixir
defmodule AuthSupport do
  use Cucumber.Hooks

  before_scenario "@authenticated", context do
    user = MyApp.Factory.insert(:user)
    token = MyApp.Auth.generate_token(user)

    {:ok, Map.merge(context, %{
      current_user: user,
      auth_token: token
    })}
  end
end
```

### Performance Monitoring

```elixir
defmodule PerformanceSupport do
  use Cucumber.Hooks

  before_scenario "@performance", context do
    start_time = System.monotonic_time()
    {:ok, Map.put(context, :start_time, start_time)}
  end

  after_scenario "@performance", context do
    duration = System.monotonic_time() - context.start_time
    milliseconds = System.convert_time_unit(duration, :native, :millisecond)

    IO.puts("Scenario completed in #{milliseconds}ms")
    :ok
  end
end
```

## Configuration

By default, support files are loaded from `test/features/support/**/*.exs`. You can customize this in your config:

```elixir
# config/test.exs
config :cucumber,
  support: ["test/support/**/*.exs", "test/cucumber_support/**/*.exs"]
```

## Best Practices

1. **Keep hooks focused** - Each hook should have a single responsibility
2. **Use tags wisely** - Don't create too many specialized hooks
3. **Avoid side effects** - Hooks should be predictable and repeatable
4. **Clean up in after hooks** - Ensure proper cleanup even if scenarios fail
5. **Use context passing** - Share data between hooks and steps via context

## Troubleshooting

### Hooks not running

1. Ensure your support files are in the correct directory
2. Verify the module uses `Cucumber.Hooks`
3. Check that tags match exactly (including the @ symbol)
4. Confirm the file has a `.exs` extension

### Hook execution order

Remember that:
- Before hooks run in definition order
- After hooks run in reverse definition order
- Tagged hooks only run when tags match