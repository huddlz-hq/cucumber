defmodule DatabaseExampleSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "a step that checks database setup", context do
    # Just pass through
    context
  end

  step "database should not be setup", context do
    assert context[:database_setup] == nil
    context
  end

  step "database should be setup", context do
    assert context[:database_setup] == true
    context
  end
end
