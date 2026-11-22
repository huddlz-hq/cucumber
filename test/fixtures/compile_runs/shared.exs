defmodule CompileRuns.Shared do
  @moduledoc false

  use Cucumber.Hooks
  use Cucumber.StepDefinition

  before_all context do
    resource = System.unique_integer([:positive])
    Cucumber.log(context, "acquired #{resource}")
    %{resource: resource}
  end

  after_all context do
    Cucumber.log(context, "released #{context.resource}")
  end

  step "use the resource for {word}", %{args: [name]} = context do
    Cucumber.log(context, "#{name} #{context.resource}")
    if name == "first", do: send(CompileRuns.Driver, :first_recorded)
    :ok
  end
end
