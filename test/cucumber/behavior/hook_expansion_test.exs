defmodule Cucumber.HookExpansionTest do
  @moduledoc """
  Behavior tests for run-level hooks (BeforeAll/AfterAll), step hooks, and
  named hooks (#27), driven by the vendored CCK `global-hooks`,
  `global-hooks-beforeall-error`, `global-hooks-afterall-error`,
  `hooks-named`, and `hooks-conditional` samples plus inline features.

  AfterAll hooks fire automatically at the end of the harness's nested
  `ExUnit.run` (the same `ExUnit.after_suite` callback as a real run).
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defp fixture(sample) do
    File.read!(Path.join(["test/fixtures/cck", sample, "#{sample}.feature"]))
  end

  defp count(events, event), do: Enum.count(events, &(&1 == event))

  defmodule Steps do
    use Cucumber.StepDefinition

    step "a step passes", _context do
      Collector.record(:step_passed)
      :ok
    end

    step "a step fails", _context do
      raise "Exception in step"
    end

    step "the before-all context is visible", context do
      Collector.record({:saw_before_all, Map.get(context, :provisioned)})
      :ok
    end
  end

  describe "BeforeAll/AfterAll (CCK global-hooks)" do
    defmodule GlobalHooks do
      use Cucumber.Hooks

      before_all context, name: "first before-all" do
        Collector.record(:before_all_one)
        {:ok, Map.put(context, :provisioned, true)}
      end

      before_all _context, name: "second before-all" do
        Collector.record(:before_all_two)
        :ok
      end

      after_all _context, name: "first after-all" do
        Collector.record(:after_all_one)
        :ok
      end

      after_all context, name: "second after-all" do
        Collector.record({:after_all_two, context.suite_result.total})
        :ok
      end
    end

    test "global hooks bracket the run; AfterAll runs in reverse order" do
      run = run_feature(fixture("global-hooks"), steps: [Steps], hooks: [GlobalHooks])

      # One passing, one failing scenario — exactly as the reference
      assert %{total: 2, failures: 1, passed: 1} = run

      # BeforeAll hooks ran exactly once each, in definition order, before
      # any scenario; AfterAll hooks ran once each in REVERSE order after
      # everything, receiving the suite result
      assert [:before_all_one, :before_all_two | scenario_events] = run.events
      assert [{:after_all_two, 2}, :after_all_one] = Enum.take(scenario_events, -2)
      assert count(run.events, :before_all_one) == 1
      assert count(run.events, :after_all_one) == 1
    end

    test "BeforeAll runs exactly once across multiple feature modules" do
      run =
        run_features(
          [
            """
            Feature: first
              Scenario: one
                Given the before-all context is visible
            """,
            """
            Feature: second
              Scenario: two
                Given the before-all context is visible
            """
          ],
          steps: [Steps],
          hooks: [GlobalHooks]
        )

      assert %{total: 2, failures: 0, passed: 2} = run
      assert count(run.events, :before_all_one) == 1
      assert count(run.events, :before_all_two) == 1
      # The before_all context reached every scenario in both modules
      assert count(run.events, {:saw_before_all, true}) == 2
    end

    test "BeforeAll runs exactly once for concurrent async scenarios" do
      run =
        run_feature(
          """
          @async
          Feature: concurrent
            Scenario: one
              Given the before-all context is visible

            Scenario: two
              Given the before-all context is visible

            Scenario: three
              Given the before-all context is visible
          """,
          steps: [Steps],
          hooks: [GlobalHooks]
        )

      assert %{total: 3, failures: 0, passed: 3} = run
      assert count(run.events, :before_all_one) == 1
      assert count(run.events, {:saw_before_all, true}) == 3
    end
  end

  describe "BeforeAll errors (CCK global-hooks-beforeall-error)" do
    defmodule BeforeAllErrorHooks do
      use Cucumber.Hooks

      before_all _context, name: "first" do
        Collector.record(:before_all_first)
        :ok
      end

      before_all _context, name: "exploding" do
        Collector.record(:before_all_exploding)
        raise "BeforeAll hook went wrong"
      end

      before_all _context, name: "third" do
        Collector.record(:before_all_third)
        :ok
      end

      after_all _context, name: "cleanup one" do
        Collector.record(:after_all_cleanup_one)
        :ok
      end

      after_all _context, name: "cleanup two" do
        Collector.record(:after_all_cleanup_two)
        :ok
      end
    end

    test "a BeforeAll failure fails every scenario; remaining global hooks still run" do
      run =
        run_feature(fixture("global-hooks-beforeall-error"),
          steps: [Steps],
          hooks: [BeforeAllErrorHooks]
        )

      # The reference does not execute test cases at all; here every
      # scenario fails with the BeforeAll error before any step or
      # scenario hook runs
      assert %{total: 1, failures: 1, passed: 0} = run
      assert run.output =~ ~s(BeforeAll hook "exploding")
      assert run.output =~ "BeforeAll hook went wrong"
      refute :step_passed in run.events

      # Remaining BeforeAll hooks still ran (CCK: set up as much as
      # possible so cleanup can do its job), and AfterAll hooks ran too
      assert :before_all_third in run.events
      assert :after_all_cleanup_one in run.events
      assert :after_all_cleanup_two in run.events
    end
  end

  describe "AfterAll errors (CCK global-hooks-afterall-error)" do
    defmodule AfterAllErrorHooks do
      use Cucumber.Hooks

      after_all _context, name: "first defined" do
        Collector.record(:after_all_first_defined)
        :ok
      end

      after_all _context, name: "exploding" do
        Collector.record(:after_all_exploding)
        raise "AfterAll hook went wrong"
      end

      after_all _context, name: "last defined" do
        Collector.record(:after_all_last_defined)
        :ok
      end
    end

    test "an AfterAll failure fails the run; remaining AfterAll hooks still run" do
      # The failure surfaces where it does in a real run: raised from the
      # suite-end callback, failing `mix test` itself
      assert_raise RuntimeError, "AfterAll hook went wrong", fn ->
        run_feature(fixture("global-hooks-afterall-error"),
          steps: [Steps],
          hooks: [AfterAllErrorHooks]
        )
      end

      events = Collector.events()

      # The scenario itself passed and every AfterAll hook ran (reverse
      # order), despite the middle one failing
      assert :step_passed in events

      assert Enum.take(events, -3) == [
               :after_all_last_defined,
               :after_all_exploding,
               :after_all_first_defined
             ]
    end
  end

  describe "step hooks" do
    defmodule StepHooks do
      use Cucumber.Hooks

      before_step context do
        Collector.record({:before_step, context.step.text})
        :ok
      end

      after_step context do
        Collector.record({:after_step, context.step.text, context.step_status})
        :ok
      end
    end

    test "step hooks bracket every step, including background steps, with status" do
      run =
        run_feature(
          """
          Feature: step hooks
            Background:
              Given a step passes

            Scenario: two more steps
              Given a step passes
              And a step fails
          """,
          steps: [Steps],
          hooks: [StepHooks]
        )

      assert %{total: 1, failures: 1} = run

      assert run.events == [
               {:before_step, "a step passes"},
               :step_passed,
               {:after_step, "a step passes", :passed},
               {:before_step, "a step passes"},
               :step_passed,
               {:after_step, "a step passes", :passed},
               {:before_step, "a step fails"},
               {:after_step, "a step fails", :failed}
             ]
    end

    test "after_step sees :skipped and :pending statuses" do
      defmodule SignalSteps do
        use Cucumber.StepDefinition

        step "a step that skips", _context do
          :skipped
        end

        step "a pending step", _context do
          :pending
        end
      end

      run =
        run_feature(
          """
          Feature: signals
            Scenario: skips
              Given a step that skips

            Scenario: pends
              Given a pending step
          """,
          steps: [SignalSteps],
          hooks: [StepHooks]
        )

      assert %{total: 2, failures: 1} = run
      assert {:after_step, "a step that skips", :skipped} in run.events
      assert {:after_step, "a pending step", :pending} in run.events
    end

    test "a failing before_step hook fails the scenario and skips the step body" do
      defmodule FailingBeforeStepHooks do
        use Cucumber.Hooks

        before_step _context, name: "guard rail" do
          Collector.record(:before_step_guard)
          {:error, "not safe to proceed"}
        end
      end

      run =
        run_feature(
          """
          Feature: guarded
            Scenario: never executes its step
              Given a step passes
          """,
          steps: [Steps],
          hooks: [FailingBeforeStepHooks]
        )

      assert %{total: 1, failures: 1} = run
      assert run.output =~ ~s(Before step hook "guard rail" failed)
      assert run.output =~ "not safe to proceed"
      refute :step_passed in run.events
    end

    test "a :skipped signal from a before_step hook skips the rest of the scenario" do
      defmodule SkippingBeforeStepHooks do
        use Cucumber.Hooks

        before_step _context do
          Collector.record(:before_step_skip)
          :skipped
        end
      end

      run =
        run_feature(
          """
          Feature: hook skip
            Scenario: skipped by step hook
              Given a step passes
          """,
          steps: [Steps],
          hooks: [SkippingBeforeStepHooks]
        )

      assert %{total: 1, failures: 0, passed: 1} = run
      assert run.output =~ "Cucumber: skipped scenario"
      refute :step_passed in run.events
    end

    test "tagged step hooks only fire for matching scenarios" do
      defmodule TaggedStepHooks do
        use Cucumber.Hooks

        before_step "@traced", _context do
          Collector.record(:traced_step)
          :ok
        end
      end

      run =
        run_feature(
          """
          Feature: tagged step hooks
            @traced
            Scenario: traced
              Given a step passes

            Scenario: untraced
              Given a step passes
          """,
          steps: [Steps],
          hooks: [TaggedStepHooks]
        )

      assert %{total: 2, failures: 0} = run
      assert count(run.events, :traced_step) == 1
    end
  end

  describe "named hooks (CCK hooks-named)" do
    defmodule NamedHooks do
      use Cucumber.Hooks

      before_scenario _context, name: "A named before hook" do
        Collector.record(:named_before)
        :ok
      end

      after_scenario _context, name: "A named after hook" do
        Collector.record(:named_after)
        :ok
      end
    end

    test "named hooks work exactly like regular hooks" do
      run = run_feature(fixture("hooks-named"), steps: [Steps], hooks: [NamedHooks])

      assert %{total: 1, failures: 0, passed: 1} = run
      assert run.events == [:named_before, :step_passed, :named_after]
    end

    test "a named before hook's name appears in its failure output" do
      defmodule FailingNamedHooks do
        use Cucumber.Hooks

        before_scenario _context, name: "prepare database" do
          {:error, "connection refused"}
        end
      end

      run =
        run_feature(
          """
          Feature: named failure
            Scenario: never starts
              Given a step passes
          """,
          steps: [Steps],
          hooks: [FailingNamedHooks]
        )

      assert %{total: 1, failures: 1} = run
      assert run.output =~ ~s(Before hook "prepare database" failed)
      assert run.output =~ "connection refused"
    end

    test "names allow several hooks of the same kind in one module" do
      defmodule MultipleNamedHooks do
        use Cucumber.Hooks

        before_scenario _context, name: "first" do
          Collector.record(:multi_first)
          :ok
        end

        before_scenario _context, name: "second" do
          Collector.record(:multi_second)
          :ok
        end
      end

      run =
        run_feature(
          """
          Feature: multiple named
            Scenario: ok
              Given a step passes
          """,
          steps: [Steps],
          hooks: [MultipleNamedHooks]
        )

      assert %{total: 1, failures: 0, passed: 1} = run
      assert run.events == [:multi_first, :multi_second, :step_passed]
    end
  end

  describe "conditional hooks (CCK hooks-conditional)" do
    defmodule ConditionalHooks do
      use Cucumber.Hooks

      before_scenario "@passing-hook", _context do
        Collector.record(:passing_before)
        :ok
      end

      before_scenario "@fail-before", _context do
        raise "Exception in conditional hook"
      end

      after_scenario "@fail-after", _context do
        raise "Exception in conditional hook"
      end

      after_scenario "@passing-hook", _context do
        Collector.record(:passing_after)
        :ok
      end
    end

    test "tagged hooks fail only their matching scenarios" do
      run = run_feature(fixture("hooks-conditional"), steps: [Steps], hooks: [ConditionalHooks])

      # @fail-before and @fail-after scenarios fail; @passing-hook passes
      assert %{total: 3, failures: 2, passed: 1} = run
      assert run.output =~ "Exception in conditional hook"

      # The @fail-before scenario never ran its step; @fail-after and
      # @passing-hook each did
      assert count(run.events, :step_passed) == 2
      assert :passing_before in run.events
      assert :passing_after in run.events
    end
  end
end
