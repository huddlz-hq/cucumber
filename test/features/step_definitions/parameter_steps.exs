defmodule ParameterSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  # Step with {int} parameter
  step "a number {int}", %{args: [number]} = context do
    assert number == 42
    Map.put(context, :number, number)
  end

  # Step with {float} parameter
  step "a decimal {float}", %{args: [float]} = context do
    assert float == 3.14
    Map.put(context, :float, float)
  end

  # Step with {string} and {word} parameters
  step "I click {string} on the {word}", context do
    [button_text, form_name] = context.args
    assert button_text == "Submit"
    assert form_name == "form"
    Map.put(context, :clicked, button_text)
  end

  # Step with {string} and {word} parameters that uses the context from previous steps
  step "I should see {string} message on the {word}", context do
    [message, location] = context.args
    assert message == "Success"
    assert location == "dashboard"
    assert context[:number] == 42
    assert context[:float] == 3.14
    assert context[:clicked] == "Submit"
    Map.put(context, :message, message)
  end
end
