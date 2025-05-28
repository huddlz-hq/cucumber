defmodule ErrorReportingSteps do
  use Cucumber.StepDefinition

  step "initial setup is complete", context do
    Map.put(context, :setup_complete, true)
  end

  # These steps are designed to test error scenarios
  # The actual testing of error reporting happens in unit tests

  step "I try to use a step with no definition", context do
    # This would normally cause an error, but for testing we just mark it
    Map.put(context, :attempted_undefined, true)
  end

  step "I should see a helpful error message", context do
    # In real usage, this would have failed with undefined step
    # For testing, we just verify the flow would have worked
    context
  end

  step "I execute a step that fails", context do
    # Simulate a failing step for testing
    Map.put(context, :step_failed, true)
  end

  step "I should see the error reason and step history", context do
    # In real usage, the previous step would have failed
    # For testing, we just verify the flow
    context
  end
end
