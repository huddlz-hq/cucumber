# Cucumber Library Bug Report: Async Test Execution with Database Sandbox

## Summary

The Cucumber library (v0.4.1) fails to properly handle database sandbox connections when tests are marked with `@async` tag and use ExUnit's database sandbox setup. This results in `DBConnection.OwnershipError` errors across all feature tests.

## Environment

- Elixir: 1.18.4
- Cucumber: 0.4.1
- Ecto: 3.12.5
- Ecto SQL: 3.12.1
- ExUnit: 1.18.4

## Bug Description

When Cucumber feature tests are configured to run asynchronously using the `@async` tag and database sandbox setup is moved to a tag-based hook system (following standard ExUnit patterns), all database operations fail with ownership errors.

## Steps to Reproduce

1. **Configure hooks to use tag-based database setup:**

```elixir
# test/features/support/hooks.exs
defmodule CucumberHooks do
  use Cucumber.Hooks
  import Huddlz.DataCase

  # Hook for @database tag - sets up database sandbox
  before_scenario "@database", context do
    setup_sandbox(context)
    {:ok, context}
  end
end
```

2. **Add @async and @database tags to feature files:**

```gherkin
@async
@database
@conn
Feature: Create Huddl
  As a group owner or organizer
  I want to create huddlz for my groups
  So that members know when and where to meet
```

3. **Use standard DataCase.setup_sandbox/1 function:**

```elixir
# test/support/data_case.ex
def setup_sandbox(tags) do
  pid = Sandbox.start_owner!(Huddlz.Repo, shared: not tags[:async])
  on_exit(fn -> Sandbox.stop_owner(pid) end)
end
```

4. **Run tests:**

```bash
mix test test/features/
```

## Expected Behavior

- Tests marked with `@async` should run concurrently with proper database isolation
- Each test process should have its own database sandbox connection
- No ownership errors should occur

## Actual Behavior

All tests fail with `DBConnection.OwnershipError`:

```
** (DBConnection.OwnershipError) cannot find ownership process for #PID<0.588.0>.

When using ownership, you must manage connections in one
of the four ways:

* By explicitly checking out a connection
* By explicitly allowing a spawned process
* By running the pool in shared mode
* By using :caller option with allowed process

...

See Ecto.Adapters.SQL.Sandbox docs for more information.
```

## Root Cause Analysis

The issue appears to be that Cucumber's test execution model doesn't properly propagate the database sandbox ownership context when:

1. Tests are marked as async
2. Database setup is done via hooks rather than globally
3. The `tags` parameter passed to hooks doesn't include the `:async` key that ExUnit uses

### Key Observations:

1. **Process Isolation Issue**: The error mentions "cannot find ownership process", suggesting that Cucumber spawns test processes in a way that doesn't maintain the sandbox ownership chain.

2. **Tag Context Issue**: The `context` passed to `before_scenario` hooks may not contain the same tag metadata that ExUnit expects (specifically the `:async` key).

3. **Hook Execution Timing**: The hooks may be executing in a different process context than the actual test steps, breaking the ownership chain.

## Workaround

The previous implementation worked around this issue by:

1. Using a global `before_scenario` hook (without tag filtering)
2. Manually checking out the sandbox connection in shared mode for all tests
3. Not using the `@async` tag

```elixir
# Previous working implementation
before_scenario context do
  CucumberDatabaseHelper.ensure_sandbox()
  {:ok, context}
end

# Where ensure_sandbox manually handled checkout:
def ensure_sandbox do
  case Sandbox.checkout(Huddlz.Repo) do
    :ok ->
      Sandbox.mode(Huddlz.Repo, {:shared, self()})
      :ok
    {:already, :owner} ->
      Sandbox.mode(Huddlz.Repo, {:shared, self()})
      :ok
  end
end
```

## Impact

This bug prevents Cucumber tests from:
1. Running in true async mode with proper isolation
2. Following standard ExUnit patterns for database setup
3. Leveraging ExUnit's optimized async test execution

## Suggested Fix

The Cucumber library should:

1. **Ensure tag metadata includes async flag**: When compiling features with `@async` tag, ensure the context passed to hooks includes `async: true`

2. **Maintain process ownership**: Ensure that hooks and step executions happen in the same process context, or properly delegate ownership

3. **Support ExUnit sandbox patterns**: Provide documentation or built-in support for ExUnit's database sandbox patterns

4. **Example implementation suggestion**:

```elixir
# In Cucumber's test compilation
def compile_test(feature, scenario) do
  # Ensure async tag is properly propagated
  tags = parse_tags(feature, scenario)
  async = :async in tags
  
  # Pass proper context to setup
  quote do
    setup context do
      # Merge tags into context for hooks
      context = Map.put(context, :async, unquote(async))
      # ... rest of setup
    end
  end
end
```

## Additional Notes

- All 34 feature tests fail with the same error pattern
- The issue is consistent across different types of tests (CRUD operations, queries, etc.)
- Using `shared: true` mode for all tests (removing async) would work but defeats the purpose of async testing
- The error occurs at the first database operation in each test, typically during test data setup

## Reproduction Repository

The issue can be reproduced in the Huddlz application by applying the changes described in this report. The previous working implementation using `CucumberDatabaseHelper` can be found in the git history.