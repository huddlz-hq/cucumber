defmodule Cucumber.TestCaseTest do
  use ExUnit.Case, async: true

  alias Cucumber.StepRegistry
  alias Cucumber.TestCase
  alias Cucumber.TestCase.HookStep
  alias Cucumber.TestCase.PickleTestStep

  defmodule Steps do
    use Cucumber.StepDefinition

    step "the app is running", context do
      context
    end

    step "I have {int} cukes", context do
      context
    end

    step "I have {int} {word}", context do
      context
    end
  end

  defmodule Types do
    use Cucumber.ParameterTypes

    parameter_type(:exploding,
      regexp: ~r/apples/,
      transform: fn _ -> raise "transform ran while building the test case" end
    )
  end

  defmodule TransformSteps do
    use Cucumber.StepDefinition

    step "I have {int} {exploding}", context do
      context
    end
  end

  defmodule Hooks do
    use Cucumber.Hooks

    before_scenario _context, name: "global before" do
      :ok
    end

    before_scenario "@database", _context, name: "database before" do
      :ok
    end

    before_scenario "@other", _context, name: "other before" do
      :ok
    end

    after_scenario _context, name: "first after" do
      :ok
    end

    after_scenario "database", _context, name: "database after" do
      :ok
    end

    before_step _context do
      :ok
    end
  end

  @feature """
  Feature: Test cases

    Background:
      Given the app is running

    Scenario: Cukes
      Given I have 3 apples
      And I have 3 cukes
      Then nothing matches this
  """

  setup do
    [pickle] = @feature |> Gherkin.Parser.parse() |> Map.put(:file, "f.feature") |> pickles()

    %{
      scenario: %{pickle_id: pickle.id, pickle_steps: pickle.steps},
      pickle: pickle,
      registry: StepRegistry.new([Steps]),
      hooks: Cucumber.Hooks.collect_hooks([Hooks])
    }
  end

  defp pickles(feature), do: Gherkin.Pickles.compile(feature).pickles

  describe "new/4 hook steps" do
    test "selects scenario hooks whose tag matches, with or without the @", ctx do
      test_case = TestCase.new(ctx.scenario, ctx.registry, ctx.hooks, ["database"])

      assert hook_names(test_case.before_hooks) == ["global before", "database before"]
      assert hook_names(test_case.after_hooks) == ["database after", "first after"]
    end

    test "combined feature and scenario tags select every matching hook once", ctx do
      test_case = TestCase.new(ctx.scenario, ctx.registry, ctx.hooks, ["database", "other"])

      assert hook_names(test_case.before_hooks) ==
               ["global before", "database before", "other before"]

      assert hook_names(test_case.after_hooks) == ["database after", "first after"]
    end

    test "untagged scenarios get only the global hooks", ctx do
      test_case = TestCase.new(ctx.scenario, ctx.registry, ctx.hooks, [])

      assert hook_names(test_case.before_hooks) == ["global before"]
      assert hook_names(test_case.after_hooks) == ["first after"]
    end

    test "after hooks run in reverse definition order", ctx do
      test_case = TestCase.new(ctx.scenario, ctx.registry, ctx.hooks, ["database"])

      assert hook_names(test_case.after_hooks) == ["database after", "first after"]
    end

    test "step hooks and run hooks are not test steps", ctx do
      test_case = TestCase.new(ctx.scenario, ctx.registry, ctx.hooks, ["database"])

      refs = Enum.map(test_case.before_hooks ++ test_case.after_hooks, & &1.ref)
      assert length(refs) == 4
      assert Enum.all?(refs, fn {Hooks, _function} -> true end)
    end
  end

  describe "new/4 pickle steps" do
    test "keeps the pickle's steps in order, marking background steps", ctx do
      test_case = TestCase.new(ctx.scenario, ctx.registry, ctx.hooks, [])

      assert Enum.map(test_case.pickle_test_steps, &{&1.step.text, &1.background?}) == [
               {"the app is running", true},
               {"I have 3 apples", false},
               {"I have 3 cukes", false},
               {"nothing matches this", false}
             ]

      assert Enum.map(test_case.pickle_test_steps, & &1.pickle_step_id) ==
               Enum.map(ctx.pickle.steps, & &1.id)
    end

    test "carries the step definitions each step matches, without its args", ctx do
      test_case = TestCase.new(ctx.scenario, ctx.registry, ctx.hooks, [])

      assert [
               %PickleTestStep{match: {:ok, %{source: "the app is running"}}},
               %PickleTestStep{match: {:ok, %{source: "I have {int} {word}"}}},
               %PickleTestStep{match: {:ambiguous, [%{source: "I have {int} cukes"}, _]}},
               %PickleTestStep{match: :undefined}
             ] = test_case.pickle_test_steps
    end

    test "does not run parameter type transforms", ctx do
      registry = StepRegistry.new([TransformSteps], [Types])

      test_case = TestCase.new(ctx.scenario, registry, ctx.hooks, [])

      assert [_, %PickleTestStep{match: {:ok, %{source: "I have {int} {exploding}"}}}, _, _] =
               test_case.pickle_test_steps
    end
  end

  describe "new/4 positions" do
    test "number every test step in run order: before hooks, pickle steps, after hooks", ctx do
      test_case = TestCase.new(ctx.scenario, ctx.registry, ctx.hooks, ["database"])

      assert Enum.map(TestCase.test_steps(test_case), & &1.position) == Enum.to_list(0..7)

      assert [%HookStep{position: 0}, %HookStep{position: 1}] = test_case.before_hooks
      assert Enum.map(test_case.pickle_test_steps, & &1.position) == [2, 3, 4, 5]
      assert [%HookStep{position: 6}, %HookStep{position: 7}] = test_case.after_hooks
    end

    test "carries the pickle id", ctx do
      test_case = TestCase.new(ctx.scenario, ctx.registry, ctx.hooks, [])

      assert test_case.pickle_id == ctx.pickle.id
    end
  end

  defp hook_names(hook_steps), do: Enum.map(hook_steps, & &1.name)
end
