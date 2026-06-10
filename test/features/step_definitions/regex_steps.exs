defmodule RegexFeatureSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step ~r/^a basket holding (\d+) apples(?: and (\d+) pears)?$/, %{args: [apples, pears]} do
    total = String.to_integer(apples) + String.to_integer(pears || "0")
    %{basket_total: total}
  end

  step "the regex basket total is {string}", %{args: [expected]} = context do
    assert Integer.to_string(context.basket_total) == expected
    :ok
  end
end
