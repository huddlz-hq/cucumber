defmodule FeatureTagHooks do
  use Cucumber.Hooks

  # Feature-level hook - should run in setup before background
  before_scenario "@database", context do
    {:ok, Map.put(context, :database_ready, true)}
  end

  # Scenario-level hook - should only run for @special scenarios
  before_scenario "@special", context do
    {:ok, Map.put(context, :special_permissions, true)}
  end

  # Cleanup hook
  after_scenario "@database", _context do
    # In a real app, this would clean up database connections
    :ok
  end
end
