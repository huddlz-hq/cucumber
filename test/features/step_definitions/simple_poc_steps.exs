defmodule SimplePocSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "the system is initialized", context do
    Map.put(context, :initialized, true)
  end

  step "I have the number {int}", %{args: [number]} = context do
    Map.put(context, :number, number)
  end

  step "I add {int}", %{args: [value]} = context do
    result = context.number + value
    Map.put(context, :result, result)
  end

  step "the result should be {int}", %{args: [expected]} = context do
    assert context.result == expected
    context
  end
end
