defmodule SharedStepsIntegrationSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  # Test-specific steps
  step "I navigate to my profile" do
    {:ok, %{page: :profile, navigation_history: [:home, :profile]}}
  end

  step "I view my account details", context do
    # Verify we have access to context from shared steps
    assert Map.has_key?(context, :current_user)
    assert Map.has_key?(context, :cart_items)

    Map.put(context, :viewing, :account_details)
  end
end
