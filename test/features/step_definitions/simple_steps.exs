defmodule SimpleSteps do
  use Cucumber.StepDefinition

  step "a simple step", context do
    Map.put(context, :simple, true)
  end
end
