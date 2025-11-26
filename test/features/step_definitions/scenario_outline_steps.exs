defmodule ScenarioOutlineSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "I have number {int}", %{args: [number]} = context do
    numbers = Map.get(context, :numbers, [])
    Map.put(context, :numbers, numbers ++ [number])
  end

  step "I add the numbers", context do
    sum = Enum.sum(context.numbers)
    Map.put(context, :sum, sum)
  end

  step "the result should be {int}", %{args: [expected]} = context do
    assert context.sum == expected
    context
  end

  step "I have value {word}", %{args: [value]} = context do
    Map.put(context, :value, value)
  end

  step "I see result {word}", %{args: [expected]} = context do
    assert String.upcase(context.value) == expected
    context
  end
end
