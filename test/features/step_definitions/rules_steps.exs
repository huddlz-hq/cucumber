defmodule RulesSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "a ledger entry for {string}", %{args: [entry]} = context do
    %{ledger: Map.get(context, :ledger, []) ++ [entry]}
  end

  step "I total the ledger", context do
    %{ledger_total: length(context.ledger)}
  end

  step "the ledger total is {int}", %{args: [expected]} = context do
    assert context.ledger_total == expected
    :ok
  end
end
