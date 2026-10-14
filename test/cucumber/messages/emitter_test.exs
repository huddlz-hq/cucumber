defmodule Cucumber.Messages.EmitterTest do
  # async: false — the coordinator is a named singleton holding the sink
  use ExUnit.Case, async: false

  alias Cucumber.Messages.Emitter
  alias Cucumber.RunCoordinator

  defmodule Steps do
    use Cucumber.StepDefinition

    step "a first step", context do
      context
    end

    step ~r/^a (\w+) step$/, context do
      context
    end
  end

  setup do
    RunCoordinator.ensure_started()
    on_exit(fn -> RunCoordinator.ensure_started() end)
  end

  describe "configure/6 (deprecated)" do
    @tag :tmp_dir
    test "still enables the message sink, ignoring the parameter types argument", %{
      tmp_dir: tmp_dir
    } do
      registry = Cucumber.StepRegistry.new([Steps])
      path = Path.join(tmp_dir, "messages.ndjson")

      # Called through apply/3 so the deprecation doesn't warn at compile time
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      assert apply(Emitter, :configure, [path, [], registry, [], %{"ignored" => %{}}, 5]) == :ok

      assert %{step_definition_ids: ids} = RunCoordinator.message_context()
      assert ids == %{0 => "5", 1 => "6"}
    end
  end
end
