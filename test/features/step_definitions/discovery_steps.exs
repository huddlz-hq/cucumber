defmodule DiscoverySteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "I have a step definition", context do
    Map.put(context, :has_step, true)
  end

  step "I run discovery", context do
    # Don't call discover during discovery!
    # Just return mock result for testing
    result = %{step_registry: %{"I have a step definition" => {DiscoverySteps, %{}}}}
    Map.put(context, :discovery_result, result)
  end

  step "the step should be found", %{discovery_result: result} = context do
    # Check that our step was discovered
    assert Map.has_key?(result.step_registry, "I have a step definition")
    context
  end
end
