defmodule TaggedSteps do
  use Cucumber.StepDefinition

  # Smoke test steps
  step "a simple smoke test", context do
    Map.put(context, :smoke_test, true)
  end

  step "I run with smoke tag filter", context do
    context
  end

  step "this scenario should run", context do
    context
  end

  # Regression test steps
  step "a regression test", context do
    Map.put(context, :regression_test, true)
  end

  step "I run with regression tag filter", context do
    context
  end

  # Multi-tagged scenario steps
  step "a test with multiple tags", context do
    Map.put(context, :multi_tagged, true)
  end

  step "I run with either smoke or regression tag filter", context do
    context
  end

  # Untagged scenario steps
  step "an untagged test", context do
    Map.put(context, :untagged_test, true)
  end

  step "I run with tag filters", context do
    context
  end

  step "this scenario should not run", context do
    context
  end
end
