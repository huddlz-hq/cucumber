defmodule ExecutionOrderHooks do
  use Cucumber.Hooks

  before_scenario "@track_execution", context do
    # Record that the feature hook ran
    {:ok, Map.put(context, :events, ["feature_hook"])}
  end
end
