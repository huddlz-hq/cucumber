# Cucumber Library Redesign Implementation Plan

## Overview

Transform Cucumber for Elixir from explicit test module definitions to an auto-discovery system that scans for feature files and step definitions, generating tests dynamically at runtime.

## Architecture Decisions

### Core Design Principles
- Leverage ExUnit as much as possible
- Runtime discovery and compilation
- Pattern-based configuration (like mix format)
- In-memory test generation via macros
- Maintain compatibility with existing context patterns

### File Structure (Default - Ruby Style)
```
test/
  features/
    authentication.feature
    shopping.feature
    step_definitions/
      authentication_steps.exs
      shopping_steps.exs
      common_steps.exs
    support/
      hooks.exs
  test_helper.exs
```

### Configuration
Default configuration (no config needed):
```elixir
# Cucumber will automatically find:
# - Features: test/features/**/*.feature
# - Steps: test/features/step_definitions/**/*.exs
# - Support: test/features/support/**/*.exs
```

Custom configuration in `config/test.exs`:
```elixir
# Only needed if using non-standard paths
config :cucumber,
  features: ["test/features/**/*.feature", "test/acceptance/**/*.feature"],
  steps: ["test/features/step_definitions/**/*.exs", "test/steps/**/*.exs"]
```

### Step Definition Syntax
```elixir
# test/features/step_definitions/authentication_steps.exs
defmodule AuthenticationSteps do
  use Cucumber.StepDefinition
  
  step "I am logged in as {string}", %{args: [username]} = context do
    {:ok, Map.put(context, :current_user, username)}
  end
end
```

### Test Generation
- Triggered in `test_helper.exs` via `Cucumber.compile_features!()`
- One ExUnit test module generated per feature file
- Each scenario becomes a test case
- Background steps become setup blocks
- All generated tests tagged with `:cucumber` and feature-specific tags

### Error Handling
- Duplicate step definitions fail at load time
- Undefined steps show helpful snippets
- Maintain current error reporting quality

## Implementation Phases

### Phase 1: Core Discovery Engine
1. Create `Cucumber.Discovery` module
   - Scan for feature files based on patterns
   - Scan for step files based on patterns
   - Load and parse all files
   - Build registry of steps

2. Create `Cucumber.StepDefinition` macro module
   - Replace current `Cucumber.SharedSteps`
   - Handle step registration
   - Detect duplicates at compile time

### Phase 2: Test Generation
1. Create `Cucumber.Compiler` module
   - Generate ExUnit test modules from features
   - Map background to setup blocks
   - Add appropriate tags
   - Handle contexts properly

2. Create `Cucumber.Runtime` module
   - Execute steps with proper context
   - Handle data tables and docstrings
   - Maintain step history for errors

### Phase 3: Integration
1. Update main `Cucumber` module
   - Add `compile_features!()` function
   - Remove `__using__` macro
   - Update documentation

2. Create migration guide
   - Document conversion from old to new style
   - Provide migration script if possible

### Phase 4: Advanced Features
1. Undefined step snippets
2. Better error messages
3. Performance optimizations
4. Hook system (if needed beyond ExUnit)

## Migration Strategy

### For Existing Tests
1. Move feature files to `test/features/`
2. Extract step definitions to `test/features/step_definitions/` modules
3. Update `test_helper.exs` to call `Cucumber.compile_features!()`
4. Remove old test modules
5. Run tests to verify

### Backwards Compatibility
- Consider supporting both styles temporarily
- Deprecation warnings for old style
- Remove in next major version

## Technical Details

### Step Registry Structure
```elixir
%{
  "I am logged in as {string}" => {AuthenticationSteps, :step_impl_1, location_info},
  "I click {string}" => {CommonSteps, :step_impl_2, location_info}
}
```

### Generated Test Structure
```elixir
defmodule Test.Features.AuthenticationTest do
  use ExUnit.Case
  @moduletag :cucumber
  @moduletag :feature_authentication
  
  setup context do
    # Background steps executed here
  end
  
  @tag :scenario_user_logs_in
  test "User logs in successfully", context do
    # Scenario steps executed here
  end
end
```

### Context Flow
- ExUnit context used directly
- Background adds to context in setup
- Each step can modify context
- DataTables/DocStrings added as `:datatable`/`:docstring` keys

## Success Criteria

1. All existing Cucumber features work in new architecture
2. `mix test` runs Cucumber tests seamlessly
3. Step definitions are reusable across features
4. Error messages remain helpful
5. Performance is acceptable
6. Migration path is clear

## Open Questions

1. Should we support multiple step definition styles during transition?
2. Do we need a way to organize steps by tags/categories?
3. Should undefined steps auto-generate stub files?
4. How to handle step definition reloading in dev?

## Next Steps

1. Validate plan with simple prototype
2. Implement Phase 1 (Discovery)
3. Test with real-world scenarios
4. Iterate based on feedback