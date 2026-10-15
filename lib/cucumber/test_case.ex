defmodule Cucumber.TestCase do
  @moduledoc false

  # A pickle prepared to run (see GLOSSARY.md): its scenario hooks already
  # selected by tag and its steps already matched against the step
  # registry. Built once per scenario by Cucumber.Runtime and shared by
  # every attempt and by the Cucumber Messages emitter, so hook selection
  # and step matching happen in exactly one place.
  #
  # Test steps carry a `position` numbering them in run order — before
  # hooks, then pickle steps, then after hooks — which is the order of the
  # Cucumber Messages `testCase.testSteps`. The test case holds no message
  # ids; the emitter maps positions to ids.

  alias Cucumber.StepRegistry

  defmodule HookStep do
    @moduledoc false
    # A before or after scenario hook, selected for this test case.
    @enforce_keys [:position, :name, :ref]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            position: non_neg_integer(),
            name: String.t() | nil,
            ref: {module(), atom()}
          }
  end

  defmodule PickleStep do
    @moduledoc false
    # One of the pickle's steps with the result of matching its text
    # against the step registry, exactly as StepRegistry.match/2 returned it.
    @enforce_keys [:position, :step, :pickle_step_id, :background?, :match]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            position: non_neg_integer(),
            step: Gherkin.Step.t(),
            pickle_step_id: String.t() | nil,
            background?: boolean(),
            match: StepRegistry.match_result()
          }
  end

  @enforce_keys [:pickle_id, :before_hooks, :pickle_steps, :after_hooks]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          pickle_id: String.t() | nil,
          before_hooks: [HookStep.t()],
          pickle_steps: [PickleStep.t()],
          after_hooks: [HookStep.t()]
        }

  @doc false
  # `scenario` needs `:pickle_id` and `:pickle_steps` (Gherkin.PickleStep
  # structs, as Gherkin.Pickles compiles them); `tags` are the scenario's
  # and feature's tags combined, which select the scenario hooks.
  @spec new(map(), StepRegistry.t(), [Cucumber.Hooks.hook()], [String.t()]) :: t()
  def new(scenario, step_registry, hooks, tags) do
    before_hooks = Cucumber.Hooks.filter_hooks(hooks, :before_scenario, tags)
    after_hooks = hooks |> Cucumber.Hooks.filter_hooks(:after_scenario, tags) |> Enum.reverse()

    {before_hooks, next} = hook_steps(before_hooks, 0)
    {pickle_steps, next} = pickle_steps(scenario.pickle_steps, step_registry, next)
    {after_hooks, _next} = hook_steps(after_hooks, next)

    %__MODULE__{
      pickle_id: Map.get(scenario, :pickle_id),
      before_hooks: before_hooks,
      pickle_steps: pickle_steps,
      after_hooks: after_hooks
    }
  end

  @doc false
  # Matches a single step outside any test case — the path
  # Cucumber.Runtime.execute_step/3 takes.
  @spec pickle_step(Gherkin.Step.t(), StepRegistry.t()) :: PickleStep.t()
  def pickle_step(step, step_registry) do
    %PickleStep{
      position: 0,
      step: step,
      pickle_step_id: nil,
      background?: false,
      match: StepRegistry.match(step_registry, step.text)
    }
  end

  @doc false
  # Every test step in run order.
  @spec test_steps(t()) :: [HookStep.t() | PickleStep.t()]
  def test_steps(%__MODULE__{} = test_case) do
    test_case.before_hooks ++ test_case.pickle_steps ++ test_case.after_hooks
  end

  defp hook_steps(hooks, first_position) do
    Enum.map_reduce(hooks, first_position, fn {name, ref}, position ->
      {%HookStep{position: position, name: name, ref: ref}, position + 1}
    end)
  end

  defp pickle_steps(steps, step_registry, first_position) do
    Enum.map_reduce(steps, first_position, fn %Gherkin.PickleStep{} = pickle_step, position ->
      step = %PickleStep{
        position: position,
        step: pickle_step.step,
        pickle_step_id: pickle_step.id,
        background?: pickle_step.from_background,
        match: StepRegistry.match(step_registry, pickle_step.step.text)
      }

      {step, position + 1}
    end)
  end
end
