defmodule CustomParameterTypesSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "flight {iata_route} is boarding", %{args: [route]} do
    %{route: route}
  end

  step "the flight departs from {string}", %{args: [expected]} = context do
    assert context.route.from == expected
    :ok
  end

  step "the flight arrives in {string}", %{args: [expected]} = context do
    assert context.route.to == expected
    :ok
  end

  step "a task with {priority} priority", %{args: [priority]} do
    %{priority: priority}
  end

  step "the recorded priority is {string}", %{args: [expected]} = context do
    assert context.priority == expected
    :ok
  end
end
