# Shared Steps Implementation Plan

## Overview
Implement a `__using__` macro system that allows defining reusable step definitions in separate modules that can be imported into Cucumber test modules.

## Incremental Implementation Phases

### Phase 1: Minimal Implementation
Create the basic infrastructure for shared steps.

**Implementation:**
```elixir
# lib/cucumber/shared_steps.ex
defmodule Cucumber.SharedSteps do
  defmacro __using__(_opts) do
    quote do
      import Cucumber, only: [defstep: 2, defstep: 3]
      @cucumber_shared_module true
    end
  end
end
```

**Test:**
- Create a basic shared module and verify it compiles
- Verify the module can define steps using `defstep`
- Check that `@cucumber_shared_module` attribute is set

### Phase 2: Step Accumulation & Export
Add mechanism to collect and export step definitions.

**Implementation:**
```elixir
defmodule Cucumber.SharedSteps do
  defmacro __using__(_opts) do
    quote do
      import Cucumber, only: [defstep: 2, defstep: 3]
      Module.register_attribute(__MODULE__, :shared_steps, accumulate: true)
      @before_compile Cucumber.SharedSteps
    end
  end
  
  defmacro __before_compile__(_env) do
    quote do
      defmacro __using__(_opts) do
        steps = @shared_steps
        quote location: :keep do
          unquote_splicing(steps)
        end
      end
    end
  end
end
```

**Test:**
- Verify steps are accumulated in module attribute
- Check that the generated `__using__` macro contains all defined steps
- Test that `location: :keep` preserves source locations

### Phase 3: Integration Testing
Test shared steps with actual Cucumber feature files.

**Test Setup:**
```elixir
# test/support/shared_steps/authentication.ex
defmodule SharedSteps.Authentication do
  use Cucumber.SharedSteps
  
  defstep "I am logged in as {string}", context do
    username = List.first(context.args)
    {:ok, %{current_user: username, authenticated: true}}
  end
  
  defstep "I should be authenticated", context do
    assert context.authenticated == true
    context
  end
end

# test/cucumber_shared_steps_test.exs
defmodule CucumberSharedStepsTest do
  use Cucumber, feature: "shared_steps_test.feature"
  use SharedSteps.Authentication
  
  defstep "I navigate to my profile", context do
    {:ok, %{page: :profile}}
  end
end
```

**Feature File:**
```gherkin
# test/features/shared_steps_test.feature
Feature: Shared Steps Integration
  
  Scenario: Using shared authentication steps
    Given I am logged in as "test@example.com"
    When I navigate to my profile
    Then I should be authenticated
```

**Tests:**
- Verify the test runs successfully
- Check that context is properly passed between shared and local steps
- Ensure shared steps have access to ExUnit assertions

### Phase 4: Error Message & Debugging
Verify error reporting maintains quality.

**Test Cases:**
1. **Missing Step Error:**
   - Use undefined step from shared module
   - Verify error message suggests correct implementation location

2. **Runtime Error in Shared Step:**
   ```elixir
   defstep "this step fails", context do
     raise "Intentional error at line #{__ENV__.line}"
   end
   ```
   - Check stack trace points to correct file/line in shared module
   - Verify error includes proper step history

3. **Assertion Failure:**
   - Make assertion fail in shared step
   - Confirm error points to assertion line in shared module

### Phase 5: Advanced Features & Edge Cases

**Test Cases:**

1. **Multiple Shared Modules:**
   ```elixir
   defmodule MyTest do
     use Cucumber, feature: "test.feature"
     use SharedSteps.Authentication
     use SharedSteps.Navigation
     use SharedSteps.Database
   end
   ```

2. **Step Pattern Conflicts:**
   - Define same pattern in shared module and local test
   - Define same pattern in two different shared modules
   - Verify precedence rules (last definition wins)

3. **Shared Module Dependencies:**
   ```elixir
   defmodule SharedSteps.Advanced do
     use Cucumber.SharedSteps
     use SharedSteps.Authentication  # Shared using shared
   end
   ```

4. **Module Naming Conventions:**
   - Test with nested modules
   - Test with aliases
   - Test with dynamic module names

## Testing Strategy

### 1. Unit Tests
- Test macro expansion correctness
- Verify module attributes are set properly
- Check AST generation for step definitions

### 2. Integration Tests
- Full end-to-end tests with feature files
- Mix of shared and local steps
- Complex scenarios with multiple shared modules

### 3. Error Case Tests
- Missing steps
- Runtime errors
- Compilation errors
- Duplicate definitions

### 4. Documentation Tests
- Doctest examples in module documentation
- Example project showing best practices
- Migration guide from inline steps to shared steps

## Success Criteria

1. **Functionality:**
   - Shared steps work identically to inline steps
   - Context passing works correctly
   - All step features (parameters, datatables, docstrings) work

2. **Developer Experience:**
   - Natural, intuitive syntax
   - Clear error messages with accurate file/line info
   - Easy debugging with proper stack traces

3. **Performance:**
   - No runtime overhead vs inline steps
   - Compile-time step resolution
   - Efficient module compilation

4. **Documentation:**
   - Clear examples in module docs
   - Best practices guide
   - Common patterns documented

## Implementation Order

1. Create `Cucumber.SharedSteps` module with basic `__using__`
2. Write compilation test for shared module
3. Add step accumulation mechanism
4. Create integration test with feature file
5. Test error scenarios
6. Add support for multiple shared modules
7. Document the feature
8. Add to main Cucumber module documentation