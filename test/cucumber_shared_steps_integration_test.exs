defmodule CucumberSharedStepsIntegrationTest do
  use Cucumber, feature: "shared_steps_integration.feature"
  use SharedSteps.Authentication
  use SharedSteps.Shopping

  # Test-specific steps
  defstep "I navigate to my profile" do
    {:ok, %{page: :profile, navigation_history: [:home, :profile]}}
  end

  defstep "I view my account details", context do
    # Verify we have access to context from shared steps
    assert Map.has_key?(context, :current_user)
    assert Map.has_key?(context, :cart_items)

    Map.put(context, :viewing, :account_details)
  end
end
