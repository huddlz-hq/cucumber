defmodule ExecutionOrderSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "I record {string}", %{args: [event]} = context do
    events = Map.get(context, :events, [])
    {:ok, Map.put(context, :events, events ++ [event])}
  end

  step "the execution order should be {string}", %{args: [expected]} = context do
    actual = Enum.join(context.events, ",")
    assert actual == expected, "Expected #{expected} but got #{actual}"
    {:ok, context}
  end
end
