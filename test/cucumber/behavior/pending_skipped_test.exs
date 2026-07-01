defmodule Cucumber.PendingSkippedTest do
  @moduledoc """
  Behavior tests for pending and skipped step results (#21), driven by the
  vendored CCK `pending`, `skipped`, `hooks-skipped`, `skipped-failing-hook`,
  and `all-statuses` samples plus inline features for the Elixir-specific
  surface (`{:pending, message}` / `{:skipped, reason}`, backgrounds,
  before-hook signals).

  Scenarios within one generated module run in seed order, so multi-scenario
  fixtures are asserted via event counts and membership rather than strict
  cross-scenario ordering.
  """

  use Cucumber.BehaviorCase

  import ExUnit.CaptureIO

  alias Cucumber.BehaviorCase.Collector

  defmodule Steps do
    use Cucumber.StepDefinition

    # CCK skipped sample
    step "a step that does not skip", _context do
      Collector.record(:ran_before_skip)
      :ok
    end

    step "a step that is skipped", _context do
      Collector.record(:ran_after_skip)
      :ok
    end

    step "I skip a step", _context do
      Collector.record(:skip_signal)
      :skipped
    end

    # CCK pending sample
    step "an implemented non-pending step", _context do
      Collector.record(:ran_before_pending)
      :ok
    end

    step "an unimplemented pending step", _context do
      Collector.record(:pending_signal)
      :pending
    end

    step "an implemented step that is skipped", _context do
      Collector.record(:ran_after_pending)
      :ok
    end

    # CCK hooks-skipped / skipped-failing-hook samples
    step "a normal step", _context do
      Collector.record(:normal_step)
      :ok
    end

    step "a step that skips", _context do
      Collector.record(:step_that_skips)
      :skipped
    end

    # Message-carrying variants
    step "I skip a step with a reason", _context do
      {:skipped, "no database available in this environment"}
    end

    step "a pending step with a message", _context do
      {:pending, "TODO: wire up the payments API"}
    end
  end

  defmodule AfterHooks do
    use Cucumber.Hooks

    after_scenario _context do
      Collector.record(:after_ran)
      :ok
    end
  end

  describe "skipped steps (CCK skipped)" do
    test "skipping halts the rest of the scenario without failing it" do
      run = run_feature(fixture("skipped"), steps: [Steps])

      # Both scenarios pass: skipped is non-failing
      assert %{total: 2, failures: 0, passed: 2} = run

      # "Skipping from a step doesn't affect the previous steps"
      assert count(run.events, :ran_before_skip) == 1
      # "Skipping from a step causes the rest of the scenario to be skipped"
      # (the skip is also the first step there — nothing after it runs)
      assert count(run.events, :skip_signal) == 2
      refute :ran_after_skip in run.events

      assert run.output =~ "Cucumber: skipped scenario"
    end

    test "{:skipped, reason} carries the reason into the notice" do
      run =
        run_feature(
          """
          Feature: skip with reason
            Scenario: environment cannot run this
              Given I skip a step with a reason
          """,
          steps: [Steps]
        )

      assert %{total: 1, failures: 0, passed: 1} = run
      assert run.output =~ "Cucumber: skipped scenario \"environment cannot run this\""
      assert run.output =~ "no database available in this environment"
    end

    test "after hooks still run when a step skips" do
      run =
        run_feature(
          """
          Feature: skip then teardown
            Scenario: skips
              Given I skip a step
          """,
          steps: [Steps],
          hooks: [AfterHooks]
        )

      assert %{failures: 0, passed: 1} = run
      assert run.events == [:skip_signal, :after_ran]
    end

    test "a failing after hook following a skip fails the test case (CCK skipped-failing-hook)" do
      defmodule FailingAfterHooks do
        use Cucumber.Hooks

        after_scenario _context do
          raise "whoops"
        end
      end

      run =
        run_feature(fixture("skipped-failing-hook"), steps: [Steps], hooks: [FailingAfterHooks])

      assert %{total: 1, failures: 1} = run
      assert run.output =~ "whoops"
    end
  end

  describe "pending steps (CCK pending)" do
    test "pending fails the scenario and skips the remaining steps" do
      run = run_feature(fixture("pending"), steps: [Steps])

      # All three scenarios contain the pending step, so all three fail
      assert %{total: 3, failures: 3, passed: 0} = run
      assert run.output =~ "Cucumber.PendingStepError"
      assert run.output =~ "an unimplemented pending step"

      # "Steps before unimplemented steps are executed"
      assert count(run.events, :ran_before_pending) == 1
      assert count(run.events, :pending_signal) == 3
      # "Steps after unimplemented steps are skipped"
      refute :ran_after_pending in run.events
    end

    test "{:pending, message} carries the message into the failure" do
      run =
        run_feature(
          """
          Feature: pending with message
            Scenario: not implemented yet
              Given a pending step with a message
          """,
          steps: [Steps]
        )

      assert %{total: 1, failures: 1} = run
      assert run.output =~ "TODO: wire up the payments API"
      assert run.output =~ "a pending step with a message"
    end

    test "after hooks still run when a step is pending" do
      run =
        run_feature(
          """
          Feature: pending then teardown
            Scenario: pends
              Given an unimplemented pending step
          """,
          steps: [Steps],
          hooks: [AfterHooks]
        )

      assert %{total: 1, failures: 1} = run
      assert run.events == [:pending_signal, :after_ran]
    end
  end

  describe "pending/skipped signals from hooks (CCK hooks-skipped)" do
    defmodule HooksA do
      use Cucumber.Hooks

      before_scenario _context do
        Collector.record(:before_a)
        :ok
      end

      after_scenario _context do
        Collector.record(:after_a)
        :ok
      end
    end

    defmodule HooksB do
      use Cucumber.Hooks

      before_scenario "@skip-before", _context do
        Collector.record(:skip_before_hook)
        :skipped
      end

      after_scenario "@skip-after", _context do
        Collector.record(:skip_after_hook)
        :skipped
      end
    end

    defmodule HooksC do
      use Cucumber.Hooks

      before_scenario _context do
        Collector.record(:before_c)
        :ok
      end

      after_scenario _context do
        Collector.record(:after_c)
        :ok
      end
    end

    test "hook skip semantics match the CCK hooks-skipped sample" do
      run = run_feature(fixture("hooks-skipped"), steps: [Steps], hooks: [HooksA, HooksB, HooksC])

      # All three scenarios are non-failing
      assert %{total: 3, failures: 0, passed: 3} = run

      events = run.events

      # The first global before hook runs for every scenario
      assert count(events, :before_a) == 3
      # The @skip-before hook fires once and halts the remaining before hooks,
      # so the second global before hook only runs for the other two scenarios
      assert count(events, :skip_before_hook) == 1
      assert count(events, :before_c) == 2

      # Steps: "a step that skips" (scenario 1) runs and skips; "a normal
      # step" is skipped in the @skip-before scenario but runs in @skip-after
      assert count(events, :step_that_skips) == 1
      assert count(events, :normal_step) == 1

      # After hooks run normally in every scenario, including after skips;
      # an after hook returning :skipped only marks itself — the rest run
      assert count(events, :after_a) == 3
      assert count(events, :after_c) == 3
      assert count(events, :skip_after_hook) == 1
    end

    test "pending from a before hook fails the scenario without running steps" do
      defmodule PendingBeforeHooks do
        use Cucumber.Hooks

        before_scenario _context do
          Collector.record(:pending_before_hook)
          {:pending, "environment not provisioned yet"}
        end
      end

      run =
        run_feature(
          """
          Feature: pending before hook
            Scenario: never starts
              Given a normal step
          """,
          steps: [Steps],
          hooks: [PendingBeforeHooks, AfterHooks]
        )

      assert %{total: 1, failures: 1} = run
      assert run.output =~ "Cucumber.PendingStepError"
      assert run.output =~ "environment not provisioned yet"
      refute :normal_step in run.events
      # Unlike {:error, reason}, a pending signal still runs after hooks
      assert run.events == [:pending_before_hook, :after_ran]
    end
  end

  describe "pending/skipped in background steps" do
    test "a skipping background step skips every scenario without failing" do
      run =
        run_feature(
          """
          Feature: skipping background
            Background:
              Given I skip a step

            Scenario: first
              Given a step that does not skip

            Scenario: second
              Given a step that does not skip
          """,
          steps: [Steps],
          hooks: [AfterHooks]
        )

      assert %{total: 2, failures: 0, passed: 2} = run
      assert count(run.events, :skip_signal) == 2
      refute :ran_before_skip in run.events
      # After hooks run for skipped scenarios, including background skips
      assert count(run.events, :after_ran) == 2
    end

    test "a pending background step fails every scenario" do
      run =
        run_feature(
          """
          Feature: pending background
            Background:
              Given an unimplemented pending step

            Scenario: first
              Given a normal step

            Scenario: second
              Given a normal step
          """,
          steps: [Steps]
        )

      assert %{total: 2, failures: 2} = run
      assert run.output =~ "Cucumber.PendingStepError"
      refute :normal_step in run.events
    end
  end

  describe "all result statuses together (CCK all-statuses)" do
    defmodule AllStatusesSteps do
      use Cucumber.StepDefinition

      step ~r/^a step$/, _context do
        :ok
      end

      step ~r/^a failing step$/, _context do
        raise "whoops"
      end

      step ~r/^a pending step$/, _context do
        :pending
      end

      step ~r/^a skipped step$/, _context do
        :skipped
      end

      step ~r/^an ambiguous (.*?)$/, _context do
        :ok
      end

      step ~r/^(.*?) ambiguous step$/, _context do
        :ok
      end
    end

    test "each status resolves like the reference implementation" do
      run = run_feature(fixture("all-statuses"), steps: [AllStatusesSteps])

      # Passing and Skipped pass; Failing, Pending, Undefined, and
      # Ambiguous fail
      assert %{total: 6, failures: 4, passed: 2} = run

      assert run.output =~ "whoops"
      assert run.output =~ "Cucumber.PendingStepError"
      assert run.output =~ "Cucumber: skipped scenario \"Skipped\""
      assert run.output =~ "Ambiguous step"
      assert run.output =~ "an undefined step"
    end
  end

  describe "skipped-step bookkeeping" do
    test "unexecuted steps land in the context under :skipped_steps" do
      registry =
        for {pattern, metadata} <- Steps.__cucumber_steps__(), into: %{} do
          {Cucumber.Discovery.registry_key(pattern), {Steps, metadata}}
        end

      scenario = %{
        feature_file: "skipped_steps.feature",
        feature_tags: [],
        async: false,
        scenario_name: "skip tail",
        scenario_line: 2,
        background_steps: [],
        steps: [
          %Gherkin.Step{keyword: "Given", text: "I skip a step", line: 2},
          %Gherkin.Step{keyword: "And", text: "a step that is skipped", line: 3},
          %Gherkin.Step{keyword: "And", text: "a normal step", line: 4}
        ]
      }

      runtime_data = %{step_registry: registry, hooks: [], parameter_types: %{}}

      {context, _notice} =
        with_io(fn -> Cucumber.Runtime.run_scenario(%{}, scenario, runtime_data) end)

      assert [
               %Gherkin.Step{text: "a step that is skipped"},
               %Gherkin.Step{text: "a normal step"}
             ] = context.skipped_steps
    end
  end
end
