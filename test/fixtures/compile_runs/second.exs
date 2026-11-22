defmodule CompileRuns.Second do
  @moduledoc false

  use Cucumber.Hooks
  use Cucumber.StepDefinition

  step "check the second resource", context do
    true = is_integer(context.resource)
    :ok
  end

  after_all context do
    Cucumber.log(context, "extra cleanup #{context.resource}")
  end
end
