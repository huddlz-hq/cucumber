defmodule Cucumber.RunnerLifecycleTest do
  @moduledoc """
  Behavior tests pinning the scenario lifecycle now owned by
  `Cucumber.Runtime.run_scenario/3`: hook ordering, hook error handling,
  background execution and attribution, and after-hook context.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule Steps do
    use Cucumber.StepDefinition

    step "a background step noting {string}", %{args: [note]} = context do
      Collector.record({:background, note})
      %{background_note: note, ledger: Map.get(context, :ledger, []) ++ [note]}
    end

    step "a failing background step", _context do
      Collector.record(:failing_background)
      raise "background boom"
    end

    step "a scenario step", _context do
      Collector.record(:scenario_step)
      :ok
    end

    step "a failing scenario step", _context do
      raise "scenario boom"
    end
  end

  # A module may only define one global hook of each kind, so ordering across
  # multiple hooks is exercised across modules (definition order = module
  # order in the hooks list).
  defmodule FirstHooks do
    use Cucumber.Hooks

    before_scenario context do
      Collector.record(:before_one)
      {:ok, context}
    end

    after_scenario context do
      Collector.record({:after_one, Map.get(context, :background_note)})
      :ok
    end
  end

  defmodule SecondHooks do
    use Cucumber.Hooks

    before_scenario context do
      Collector.record(:before_two)
      {:ok, context}
    end

    after_scenario _context do
      Collector.record(:after_two)
      :ok
    end
  end

  defmodule ErroringBeforeHooks do
    use Cucumber.Hooks

    before_scenario _context do
      Collector.record(:erroring_before)
      {:error, "no database today"}
    end

    after_scenario _context do
      Collector.record(:after_despite_error)
      :ok
    end
  end

  describe "hook ordering" do
    test "before hooks run in definition order, after hooks in reverse" do
      run =
        run_feature(
          """
          Feature: ordering
            Scenario: hooks around
              Given a scenario step
          """,
          steps: [Steps],
          hooks: [FirstHooks, SecondHooks]
        )

      assert run.passed == 1

      assert run.events == [
               :before_one,
               :before_two,
               :scenario_step,
               :after_two,
               {:after_one, nil}
             ]
    end

    test "after hooks receive the post-background context" do
      run =
        run_feature(
          """
          Feature: after context
            Background:
              Given a background step noting "from-background"

            Scenario: just runs
              Given a scenario step
          """,
          steps: [Steps],
          hooks: [FirstHooks, SecondHooks]
        )

      assert run.passed == 1
      assert {:after_one, "from-background"} in run.events
    end

    test "after hooks run when a scenario step fails" do
      run =
        run_feature(
          """
          Feature: after on failure
            Scenario: fails
              Given a failing scenario step
          """,
          steps: [Steps],
          hooks: [FirstHooks, SecondHooks]
        )

      assert run.failures == 1
      assert :after_two in run.events
    end
  end

  describe "before hook errors" do
    test "{:error, reason} fails the scenario without running steps or after hooks" do
      run =
        run_feature(
          """
          Feature: hook error
            Scenario: never starts
              Given a scenario step
          """,
          steps: [Steps],
          hooks: [ErroringBeforeHooks]
        )

      assert %{total: 1, passed: 0, failures: 1} = run
      assert run.output =~ "Before hook failed"
      assert run.output =~ "no database today"
      assert run.events == [:erroring_before]
      refute :scenario_step in run.events
      refute :after_despite_error in run.events
    end
  end

  describe "background execution" do
    test "background steps thread context into scenario steps" do
      run =
        run_feature(
          """
          Feature: background context
            Background:
              Given a background step noting "first"
              And a background step noting "second"

            Scenario: uses background
              Given a scenario step
          """,
          steps: [Steps]
        )

      assert run.passed == 1
      assert run.events == [{:background, "first"}, {:background, "second"}, :scenario_step]
    end

    test "a failing background step fails the scenario at the background step's line" do
      run =
        run_feature(
          """
          Feature: failing background
            Background:
              Given a failing background step

            Scenario: unreachable
              Given a scenario step
          """,
          steps: [Steps],
          hooks: [FirstHooks, SecondHooks],
          file: "test/fixtures/generated/background_attribution.feature"
        )

      assert %{total: 1, passed: 0, failures: 1} = run
      assert run.output =~ "background boom"
      # The failure is attributed to the background step's feature line
      assert run.output =~ "background_attribution.feature:3"
      refute :scenario_step in run.events
      # Parity: after hooks are only armed once the background succeeded
      refute :after_two in run.events
    end
  end
end
