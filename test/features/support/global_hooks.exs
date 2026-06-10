defmodule GlobalHooksSupport do
  use Cucumber.Hooks

  before_all context, name: "start run-level services" do
    # Unlinked so it survives this (short-lived) calling process; the agent
    # lives for the rest of the run.
    {:ok, counter} = Agent.start(fn -> 0 end)
    {:ok, Map.put(context, :global_hooks_counter, counter)}
  end

  before_step "@counted-steps", context do
    Agent.update(context.global_hooks_counter, &(&1 + 1))
    :ok
  end
end
