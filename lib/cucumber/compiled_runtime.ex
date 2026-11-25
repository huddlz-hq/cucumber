defmodule Cucumber.CompiledRuntime do
  @moduledoc false

  @type key :: {{module(), atom(), pos_integer()}, pos_integer()}
  @type data :: %{
          step_registry: Cucumber.StepRegistry.t(),
          hooks: [Cucumber.Hooks.hook()],
          step_wrapper: term()
        }

  # Only the coordinator for this scope writes. Give each compilation a
  # separate slot so joining a run never replaces a snapshot in active use.
  @spec store(atom(), data()) :: key()
  def store(scope, data) do
    count_key = {__MODULE__, scope}
    index = :persistent_term.get(count_key, 0) + 1
    slot = {__MODULE__, scope, index}
    generation = System.unique_integer([:positive])

    :persistent_term.put(count_key, index)
    :persistent_term.put(slot, {generation, self(), data})
    {slot, generation}
  end

  @spec fetch!(key()) :: data()
  def fetch!({slot, generation}) do
    case :persistent_term.get(slot, nil) do
      {^generation, owner, data} -> if Process.alive?(owner), do: data, else: expired!()
      _ -> expired!()
    end
  end

  # Recording the count first and erasing it last lets a replacement
  # coordinator finish cleanup even if its predecessor was killed mid-write.
  @spec release(atom()) :: :ok
  def release(scope) do
    count_key = {__MODULE__, scope}
    count = :persistent_term.get(count_key, 0)

    for index <- 1..count//1, do: :persistent_term.erase({__MODULE__, scope, index})
    :persistent_term.erase(count_key)
    :ok
  end

  defp expired! do
    raise "This Cucumber feature's run has ended. Call Cucumber.compile_features!/1 again before rerunning it."
  end
end
