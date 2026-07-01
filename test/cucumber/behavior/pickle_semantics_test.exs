defmodule Cucumber.PickleSemanticsTest do
  @moduledoc """
  Behavior tests for pickle compilation semantics that reach the runner
  (#28): background steps stay verbatim under scenario outlines, and a
  scenario with no steps of its own is an empty test case — its
  background does not run.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule Steps do
    use Cucumber.StepDefinition

    # Matches the literal text, angle brackets included
    step "a template containing <b> markup", _context do
      Collector.record(:literal_background_step)
      :ok
    end

    step "I emphasise {word}", %{args: [word]} do
      Collector.record({:emphasised, word})
      :ok
    end

    step "a background step", _context do
      Collector.record(:background_step)
      :ok
    end

    step "a scenario step", _context do
      Collector.record(:scenario_step)
      :ok
    end
  end

  test "background steps are not placeholder-substituted for outline scenarios" do
    run =
      run_feature(
        """
        Feature: literal background
          Background:
            Given a template containing <b> markup

          Scenario Outline: emphasis
            Given I emphasise <b>

            Examples:
              | b     |
              | words |
              | code  |
        """,
        steps: [Steps]
      )

    # The background step still matches its literal definition in every
    # row — substituting it would make both scenarios fail as undefined
    assert %{total: 2, failures: 0, passed: 2} = run
    assert count(run.events, :literal_background_step) == 2
    assert {:emphasised, "words"} in run.events
    assert {:emphasised, "code"} in run.events
  end

  test "a scenario with no steps passes without running the background" do
    run =
      run_feature(
        """
        Feature: empty scenario
          Background:
            Given a background step

          Scenario: not written yet

          Scenario: real one
            Given a scenario step
        """,
        steps: [Steps]
      )

    assert %{total: 2, failures: 0, passed: 2} = run
    # The background ran only for the scenario that has steps
    assert count(run.events, :background_step) == 1
    assert count(run.events, :scenario_step) == 1
  end
end
