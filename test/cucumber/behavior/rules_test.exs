defmodule Cucumber.RulesBehaviorTest do
  @moduledoc """
  Behavior tests for the Rule keyword (#19), driven by the CCK `rules` and
  `rules-backgrounds` samples plus targeted cases from the issue checklist.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule ChocolateSteps do
    use Cucumber.StepDefinition
    import ExUnit.Assertions

    step "the customer has {int} cents", %{args: [money]} do
      %{money: money}
    end

    step "there are chocolate bars in stock", _context do
      %{stock: ["Mars"]}
    end

    step "there are no chocolate bars in stock", _context do
      %{stock: []}
    end

    step "the customer tries to buy a {int} cent chocolate bar", %{args: [price]} = context do
      if context.money >= price do
        %{chocolate: List.first(context.stock)}
      else
        :ok
      end
    end

    step "the sale should not happen", context do
      assert Map.get(context, :chocolate) == nil
      :ok
    end

    step "the sale should happen", context do
      assert context.chocolate
      :ok
    end
  end

  defmodule OrderSteps do
    use Cucumber.StepDefinition

    step "an order for {string}", %{args: [item]} do
      Collector.record({:order, item})
      :ok
    end

    step "an action", _context do
      Collector.record(:action)
      :ok
    end

    step "an outcome", _context do
      Collector.record(:outcome)
      :ok
    end
  end

  defmodule MarkerSteps do
    use Cucumber.StepDefinition

    step "a marker step in {string}", %{args: [where]} do
      Collector.record({:marker, where})
      :ok
    end

    step "a failing rule background step", _context do
      raise "rule background boom"
    end
  end

  defmodule RuleTagHooks do
    use Cucumber.Hooks

    before_scenario "@some-tag", context do
      Collector.record(:rule_tagged_hook)
      {:ok, context}
    end
  end

  describe "CCK: rules" do
    test "scenarios in rules execute with reference outcomes" do
      run = run_feature(fixture("rules"), steps: [ChocolateSteps])

      # 2 scenarios in the first rule + 1 in the second, all passing
      assert %{total: 3, passed: 3, failures: 0} = run
    end

    test "rule tags trigger tagged hooks for the rule's scenarios only" do
      run = run_feature(fixture("rules"), steps: [ChocolateSteps], hooks: [RuleTagHooks])

      assert %{total: 3, passed: 3} = run
      # Only the one scenario under the @some-tag rule fires the hook
      assert Enum.count(run.events, &(&1 == :rule_tagged_hook)) == 1
    end
  end

  describe "CCK: rules-backgrounds" do
    test "feature background runs before rule background before scenario steps" do
      run = run_feature(fixture("rules-backgrounds"), steps: [OrderSteps])

      assert %{total: 2, passed: 2, failures: 0} = run

      expected_scenario_events = [
        {:order, "eggs"},
        {:order, "milk"},
        {:order, "bread"},
        {:order, "batteries"},
        {:order, "light bulbs"},
        :action,
        :outcome
      ]

      assert Enum.chunk_every(run.events, 7) == [
               expected_scenario_events,
               expected_scenario_events
             ]
    end
  end

  describe "rule semantics" do
    test "identically-named scenarios in different rules both run" do
      run =
        run_feature(
          """
          Feature: name collisions
            Rule: first rule
              Scenario: same name
                Given a marker step in "first"

            Rule: second rule
              Scenario: same name
                Given a marker step in "second"
          """,
          steps: [MarkerSteps]
        )

      assert %{total: 2, passed: 2, failures: 0} = run
      assert Enum.sort(run.events) == [{:marker, "first"}, {:marker, "second"}]
    end

    test "a failing rule-background step fails the scenario and reports its line" do
      run =
        run_feature(
          """
          Feature: failing rule background
            Rule: doomed
              Background:
                Given a failing rule background step

              Scenario: never gets here
                Given a marker step in "unreachable"
          """,
          steps: [MarkerSteps],
          file: "test/fixtures/generated/rule_background.feature"
        )

      assert %{total: 1, passed: 0, failures: 1} = run
      assert run.output =~ "rule background boom"
      # The failing step's feature-file stack frame points at the rule
      # background step's line (line 4)
      assert run.output =~ "rule_background.feature:4"
      refute {:marker, "unreachable"} in run.events
    end

    test "rule tags are filterable ExUnit tags on the generated tests" do
      run =
        run_feature(
          """
          Feature: tagged rule
            @wip-rule
            Rule: tagged
              Scenario: carries the rule tag
                Given a marker step in "tagged"
          """,
          steps: [MarkerSteps]
        )

      assert %{total: 1, passed: 1} = run

      # The generated test carries the rule tag as an ExUnit tag
      test_name = :"test tagged: carries the rule tag"
      %ExUnit.TestModule{tests: tests} = run.module.__ex_unit__()
      test_tags = Enum.find(tests, &(&1.name == test_name)).tags
      assert test_tags[:"wip-rule"] == true
    end
  end
end
