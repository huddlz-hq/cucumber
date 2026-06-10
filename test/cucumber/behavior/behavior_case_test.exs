defmodule Cucumber.BehaviorCaseTest do
  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule BasicSteps do
    use Cucumber.StepDefinition

    step "a passing step", _context do
      Collector.record(:passing_step)
      :ok
    end

    step "another passing step", _context do
      Collector.record(:another_passing_step)
      :ok
    end

    step "a failing step", _context do
      Collector.record(:failing_step)
      raise "boom from step"
    end

    step "a step after the failure", _context do
      Collector.record(:after_failure)
      :ok
    end
  end

  defmodule ReturnValueSteps do
    use Cucumber.StepDefinition

    step "a step returning ok", _context do
      :ok
    end

    step "a step returning a map", _context do
      %{from_map: 1}
    end

    step "a step returning a keyword list", _context do
      [from_keyword: 2]
    end

    step "a step returning an ok tuple", _context do
      {:ok, %{from_tuple: 3}}
    end

    step "the context holds all merged values", context do
      Collector.record({:merged, context.from_map, context.from_keyword, context.from_tuple})
      :ok
    end

    step "a step returning an error tuple", _context do
      {:error, "deliberate error reason"}
    end

    step "a step returning garbage", _context do
      :unexpected_garbage
    end
  end

  defmodule ArgumentSteps do
    use Cucumber.StepDefinition

    step "I have {int} cukes and a {string} label", %{args: [count, label]} do
      Collector.record({:args, count, label})
      :ok
    end

    step "a step with a datatable:", context do
      Collector.record({:datatable, context.datatable.raw})
      :ok
    end

    step "a step with a docstring:", context do
      Collector.record({:docstring, context.docstring})
      :ok
    end
  end

  defmodule OrderHooks do
    use Cucumber.Hooks

    before_scenario context do
      Collector.record(:before_hook)
      {:ok, context}
    end

    before_scenario "@special", context do
      Collector.record(:tagged_before_hook)
      {:ok, context}
    end

    after_scenario _context do
      Collector.record(:after_hook)
      :ok
    end
  end

  describe "run_feature/2 outcome reporting" do
    test "a passing scenario reports passed" do
      run =
        run_feature(
          """
          Feature: basics
            Scenario: passes
              Given a passing step
              And another passing step
          """,
          steps: [BasicSteps]
        )

      assert run.total == 1
      assert run.passed == 1
      assert run.failures == 0
      assert run.events == [:passing_step, :another_passing_step]
    end

    test "a failing step fails the scenario with a StepError carrying the message" do
      run =
        run_feature(
          """
          Feature: basics
            Scenario: fails
              Given a passing step
              And a failing step
              And a step after the failure
          """,
          steps: [BasicSteps]
        )

      assert run.total == 1
      assert run.failures == 1
      assert run.output =~ "Cucumber.StepError"
      assert run.output =~ "boom from step"
    end

    test "steps after a failing step do not execute" do
      run =
        run_feature(
          """
          Feature: basics
            Scenario: fails midway
              Given a failing step
              And a step after the failure
          """,
          steps: [BasicSteps]
        )

      assert run.failures == 1
      assert run.events == [:failing_step]
      refute :after_failure in run.events
    end

    test "scenarios are independent: one failure does not affect other scenarios" do
      run =
        run_feature(
          """
          Feature: basics
            Scenario: good
              Given a passing step

            Scenario: bad
              Given a failing step
          """,
          steps: [BasicSteps]
        )

      assert run.total == 2
      assert run.passed == 1
      assert run.failures == 1
    end
  end

  describe "step return values" do
    test ":ok, map, keyword list, and {:ok, map} all merge into context" do
      run =
        run_feature(
          """
          Feature: returns
            Scenario: merging
              Given a step returning ok
              And a step returning a map
              And a step returning a keyword list
              And a step returning an ok tuple
              Then the context holds all merged values
          """,
          steps: [ReturnValueSteps]
        )

      assert run.passed == 1
      assert run.events == [{:merged, 1, 2, 3}]
    end

    test "{:error, reason} fails the step with the reason in the output" do
      run =
        run_feature(
          """
          Feature: returns
            Scenario: error tuple
              Given a step returning an error tuple
          """,
          steps: [ReturnValueSteps]
        )

      assert run.failures == 1
      assert run.output =~ "deliberate error reason"
    end

    test "an invalid return value fails with an explanatory message" do
      run =
        run_feature(
          """
          Feature: returns
            Scenario: garbage return
              Given a step returning garbage
          """,
          steps: [ReturnValueSteps]
        )

      assert run.failures == 1
      assert run.output =~ "Invalid step return value"
    end
  end

  describe "step arguments" do
    test "cucumber expression parameters arrive in context.args with converted types" do
      run =
        run_feature(
          """
          Feature: args
            Scenario: params
              Given I have 42 cukes and a "fresh" label
          """,
          steps: [ArgumentSteps]
        )

      assert run.passed == 1
      assert run.events == [{:args, 42, "fresh"}]
    end

    test "datatables arrive in context.datatable" do
      run =
        run_feature(
          """
          Feature: args
            Scenario: table
              Given a step with a datatable:
                | a | b |
                | 1 | 2 |
          """,
          steps: [ArgumentSteps]
        )

      assert run.passed == 1
      assert run.events == [{:datatable, [["a", "b"], ["1", "2"]]}]
    end

    test "docstrings arrive in context.docstring" do
      run =
        run_feature(
          """
          Feature: args
            Scenario: docstring
              Given a step with a docstring:
                \"\"\"
                line one
                line two
                \"\"\"
          """,
          steps: [ArgumentSteps]
        )

      assert run.passed == 1
      assert run.events == [{:docstring, "line one\nline two"}]
    end
  end

  describe "undefined steps" do
    test "an undefined step fails with a definition suggestion" do
      run =
        run_feature(
          """
          Feature: undefined
            Scenario: nothing matches
              Given a list of 8 things
          """,
          steps: [BasicSteps]
        )

      assert run.failures == 1
      assert run.output =~ "No matching step definition found"
      assert run.output =~ ~s(step "a list of {int} things")
    end
  end

  describe "scenario outlines" do
    test "each examples row runs as its own scenario" do
      run =
        run_feature(
          """
          Feature: outlines
            Scenario Outline: counting
              Given I have <count> cukes and a "<label>" label

            Examples:
              | count | label |
              |     1 | one   |
              |     2 | two   |
          """,
          steps: [ArgumentSteps]
        )

      assert run.total == 2
      assert run.passed == 2
      assert Enum.sort(run.events) == [{:args, 1, "one"}, {:args, 2, "two"}]
    end
  end

  describe "hooks" do
    test "before and after hooks bracket a scenario in order" do
      run =
        run_feature(
          """
          Feature: hooked
            Scenario: simple
              Given a passing step
          """,
          steps: [BasicSteps],
          hooks: [OrderHooks]
        )

      assert run.passed == 1
      assert run.events == [:before_hook, :passing_step, :after_hook]
    end

    test "tagged before hooks only fire for scenarios carrying the tag" do
      untagged =
        run_feature(
          """
          Feature: hooked
            Scenario: plain
              Given a passing step
          """,
          steps: [BasicSteps],
          hooks: [OrderHooks]
        )

      refute :tagged_before_hook in untagged.events

      tagged =
        run_feature(
          """
          Feature: hooked
            @special
            Scenario: special
              Given a passing step
          """,
          steps: [BasicSteps],
          hooks: [OrderHooks]
        )

      assert :tagged_before_hook in tagged.events
    end

    test "after hooks run even when the scenario fails" do
      run =
        run_feature(
          """
          Feature: hooked
            Scenario: failing
              Given a failing step
          """,
          steps: [BasicSteps],
          hooks: [OrderHooks]
        )

      assert run.failures == 1
      assert :after_hook in run.events
    end
  end
end
