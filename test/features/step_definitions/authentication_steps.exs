defmodule AuthenticationSteps do
  @moduledoc """
  Authentication steps for cucumber tests.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "I am logged in as {string}", %{args: [username]} do
    {:ok, %{current_user: username, authenticated: true}}
  end

  step "I should be authenticated", context do
    assert context.authenticated == true
    context
  end

  step "I should see {string} as the current user", %{args: [expected_user]} = context do
    assert context.current_user == expected_user
    context
  end
end
