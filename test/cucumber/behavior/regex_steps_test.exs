defmodule Cucumber.RegexStepsBehaviorTest do
  @moduledoc """
  Behavior tests for regular expression step definitions (#24).
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule RegexSteps do
    use Cucumber.StepDefinition

    step ~r/^a (.*?)(?: and a (.*?))?(?: and a (.*?))?$/, %{args: args} do
      Collector.record({:vegetables, args})
      :ok
    end
  end

  defmodule MixedSteps do
    use Cucumber.StepDefinition

    step ~r/^I count (\d+) regex cukes$/, %{args: [count]} do
      Collector.record({:regex_count, count})
      :ok
    end

    step "I count {int} regex cukes", %{args: [count]} do
      Collector.record({:expression_count, count})
      :ok
    end

    step ~r/^a zero-capture regex step$/, %{args: args} do
      Collector.record({:zero_capture, args})
      :ok
    end

    step ~r/cukes in the middle/, _context do
      Collector.record(:substring_regex)
      :ok
    end

    step ~r/^a regex step with a table:$/, context do
      Collector.record({:regex_table, context.datatable.raw})
      :ok
    end
  end

  describe "CCK: regular-expression" do
    test "capture groups arrive as strings in order, nil for unmatched optionals" do
      run =
        run_feature(
          File.read!("test/fixtures/cck/regular-expression/regular-expression.feature"),
          steps: [RegexSteps]
        )

      assert %{total: 1, passed: 1, failures: 0} = run

      assert run.events == [
               {:vegetables, ["cucumber", nil, nil]},
               {:vegetables, ["cucumber", "zucchini", nil]},
               {:vegetables, ["cucumber", "zucchini", "gourd"]}
             ]
    end
  end

  describe "regex step semantics" do
    test "a regex and an expression both matching the same text are ambiguous" do
      run =
        run_feature(
          """
          Feature: cross-kind ambiguity
            Scenario: both match
              Given I count 7 regex cukes
          """,
          steps: [MixedSteps]
        )

      assert %{total: 1, failures: 1} = run
      assert run.output =~ "Cucumber.AmbiguousStepError"
      assert run.output =~ "~r/^I count (\\d+) regex cukes$/"
      assert run.output =~ "I count {int} regex cukes"
      assert run.events == []
    end

    test "zero-capture regexes match with empty args" do
      run =
        run_feature(
          """
          Feature: zero captures
            Scenario: no groups
              Given a zero-capture regex step
          """,
          steps: [MixedSteps]
        )

      assert %{total: 1, passed: 1} = run
      assert run.events == [{:zero_capture, []}]
    end

    test "an unanchored regex still must match the entire step text" do
      run =
        run_feature(
          """
          Feature: anchoring
            Scenario: substring does not match
              Given there are cukes in the middle of this text
          """,
          steps: [MixedSteps]
        )

      # The substring regex does NOT match the longer text — full-text
      # matching is enforced, so the step is undefined.
      assert %{total: 1, failures: 1} = run
      assert run.output =~ "No matching step definition found"
      refute :substring_regex in run.events

      exact =
        run_feature(
          """
          Feature: anchoring
            Scenario: exact text matches
              Given cukes in the middle
          """,
          steps: [MixedSteps]
        )

      assert %{total: 1, passed: 1} = exact
      assert exact.events == [:substring_regex]
    end

    test "regex steps receive datatables" do
      run =
        run_feature(
          """
          Feature: regex with table
            Scenario: table attached
              Given a regex step with a table:
                | a | b |
          """,
          steps: [MixedSteps]
        )

      assert %{total: 1, passed: 1} = run
      assert run.events == [{:regex_table, [["a", "b"]]}]
    end
  end
end
