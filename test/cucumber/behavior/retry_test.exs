defmodule Cucumber.RetryTest do
  @moduledoc """
  Behavior tests for retry (#26), driven by the vendored CCK `retry`,
  `retry-undefined`, `retry-ambiguous`, and `retry-pending` samples plus
  inline features for the Elixir-specific surface (`@retry-n` tags, fresh
  context per attempt, hook re-runs).

  The CCK runs its retry samples with `--retry 2`; the equivalent here is
  `config :cucumber, retry: 2`, set per test via `with_retry_config/2`.
  Attempt counting uses the Collector: a step counts its own prior events
  to decide whether to fail, mirroring the reference step definitions'
  module-level counters.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defp with_retry_config(retries, fun) do
    Application.put_env(:cucumber, :retry, retries)

    try do
      fun.()
    after
      Application.delete_env(:cucumber, :retry)
    end
  end

  defmodule Steps do
    use Cucumber.StepDefinition

    step "a step that always passes", _context do
      Collector.record(:always_passes)
      :ok
    end

    step "a step that passes the second time", _context do
      Collector.record(:second_time)

      if Enum.count(Collector.events(), &(&1 == :second_time)) < 2 do
        raise "Exception in step"
      end

      :ok
    end

    step "a step that passes the third time", _context do
      Collector.record(:third_time)

      if Enum.count(Collector.events(), &(&1 == :third_time)) < 3 do
        raise "Exception in step"
      end

      :ok
    end

    step "a step that always fails", _context do
      Collector.record(:always_fails)
      raise "Exception in step"
    end

    step "a pending step", _context do
      Collector.record(:pending_step)
      :pending
    end

    step "a step that exits the first time", _context do
      Collector.record(:exit_step)

      if Enum.count(Collector.events(), &(&1 == :exit_step)) < 2 do
        exit(:simulated_timeout)
      end

      :ok
    end

    step "a step that throws the first time", _context do
      Collector.record(:throw_step)

      if Enum.count(Collector.events(), &(&1 == :throw_step)) < 2 do
        throw(:simulated_ball)
      end

      :ok
    end
  end

  describe "the CCK retry sample (retry limit 2)" do
    test "failing scenarios are retried up to the limit; passes aren't retried" do
      run =
        with_retry_config(2, fn ->
          run_feature(fixture("retry"), steps: [Steps])
        end)

      # Only "a step that always fails" exhausts its attempts and fails
      assert %{total: 4, failures: 1, passed: 3} = run

      # Passing test cases aren't retried
      assert count(run.events, :always_passes) == 1
      # Fail-once passes on the second attempt
      assert count(run.events, :second_time) == 2
      # Fail-twice continues retrying up to the limit
      assert count(run.events, :third_time) == 3
      # Fail-always runs retries + 1 attempts, then fails with the step error
      assert count(run.events, :always_fails) == 3

      # Each retry prints a flake warning naming the scenario
      assert run.output =~
               ~s(Cucumber: retrying scenario "Test cases that fail are retried if within the --retry limit")

      # 1 (second_time) + 2 (third_time) + 2 (always_fails)
      assert length(String.split(run.output, "Cucumber: retrying scenario")) - 1 == 5

      # The exhausted scenario fails with the step's own error
      assert run.output =~ "Exception in step"
    end
  end

  describe "statuses that never retry" do
    test "undefined scenarios run exactly once (CCK retry-undefined)" do
      run =
        with_retry_config(2, fn ->
          run_feature(fixture("retry-undefined"), steps: [Steps])
        end)

      assert %{total: 1, failures: 1} = run
      assert run.output =~ "No matching step definition"
      refute run.output =~ "Cucumber: retrying scenario"
    end

    test "ambiguous scenarios run exactly once (CCK retry-ambiguous)" do
      defmodule AmbiguousSteps do
        use Cucumber.StepDefinition

        step "an ambiguous step", _context do
          :ok
        end

        step ~r/^an ambiguous (.*)$/, _context do
          :ok
        end
      end

      run =
        with_retry_config(2, fn ->
          run_feature(fixture("retry-ambiguous"), steps: [AmbiguousSteps])
        end)

      assert %{total: 1, failures: 1} = run
      assert run.output =~ "Ambiguous step"
      refute run.output =~ "Cucumber: retrying scenario"
    end

    test "pending scenarios run exactly once (CCK retry-pending)" do
      run =
        with_retry_config(2, fn ->
          run_feature(fixture("retry-pending"), steps: [Steps])
        end)

      assert %{total: 1, failures: 1} = run
      assert run.output =~ "Cucumber.PendingStepError"
      assert count(run.events, :pending_step) == 1
      refute run.output =~ "Cucumber: retrying scenario"
    end
  end

  describe "retry limits" do
    test "without config or tag, a failing scenario runs exactly once" do
      run =
        run_feature(
          """
          Feature: no retry
            Scenario: fails once
              Given a step that passes the second time
          """,
          steps: [Steps]
        )

      assert %{total: 1, failures: 1} = run
      assert count(run.events, :second_time) == 1
      refute run.output =~ "Cucumber: retrying scenario"
    end

    test "a @retry-n tag enables retries without global config" do
      run =
        run_feature(
          """
          Feature: tagged retry
            @retry-1
            Scenario: flaky
              Given a step that passes the second time
          """,
          steps: [Steps]
        )

      assert %{total: 1, failures: 0, passed: 1} = run
      assert count(run.events, :second_time) == 2
    end

    test "a feature-level @retry-n tag applies to its scenarios" do
      run =
        run_feature(
          """
          @retry-2
          Feature: feature-wide retry
            Scenario: flaky
              Given a step that passes the third time
          """,
          steps: [Steps]
        )

      assert %{total: 1, failures: 0, passed: 1} = run
      assert count(run.events, :third_time) == 3
    end

    test "a @retry-0 tag overrides the global config to a single attempt" do
      run =
        with_retry_config(2, fn ->
          run_feature(
            """
            Feature: tag beats config
              @retry-0
              Scenario: not retried
                Given a step that passes the second time
            """,
            steps: [Steps]
          )
        end)

      assert %{total: 1, failures: 1} = run
      assert count(run.events, :second_time) == 1
    end

    test "a scenario-level @retry-0 exempts the scenario from a feature-level retry tag" do
      run =
        run_feature(
          """
          @retry-2
          Feature: feature-wide retry with an exemption
            @retry-0
            Scenario: exempt
              Given a step that passes the second time
          """,
          steps: [Steps]
        )

      assert %{total: 1, failures: 1} = run
      assert count(run.events, :second_time) == 1
      refute run.output =~ "Cucumber: retrying scenario"
    end

    test "a scenario-level @retry-n beats a feature-level @retry-0" do
      run =
        run_feature(
          """
          @retry-0
          Feature: opt-in under an exempt feature
            @retry-1
            Scenario: flaky
              Given a step that passes the second time
          """,
          steps: [Steps]
        )

      assert %{total: 1, failures: 0, passed: 1} = run
      assert count(run.events, :second_time) == 2
    end

    test "retry: nil in config means no retry" do
      run =
        with_retry_config(nil, fn ->
          run_feature(
            """
            Feature: nil retry config
              Scenario: fails once
                Given a step that passes the second time
            """,
            steps: [Steps]
          )
        end)

      assert %{total: 1, failures: 1} = run
      assert count(run.events, :second_time) == 1
    end

    test "a non-integer retry config fails with a clear error" do
      run =
        with_retry_config("2", fn ->
          run_feature(
            """
            Feature: bad retry config
              Scenario: any
                Given a step that always passes
            """,
            steps: [Steps]
          )
        end)

      assert %{total: 1, failures: 1} = run
      assert run.output =~ "config :cucumber, :retry must be an integer"
      assert run.output =~ ~s("2")
    end
  end

  describe "failures that aren't raised exceptions" do
    test "an exit (e.g. a call timeout) is retried like a raised exception" do
      run =
        run_feature(
          """
          Feature: exit retry
            @retry-1
            Scenario: exits once
              Given a step that exits the first time
          """,
          steps: [Steps]
        )

      assert %{total: 1, failures: 0, passed: 1} = run
      assert count(run.events, :exit_step) == 2
      assert run.output =~ "Cucumber: retrying scenario"
    end

    test "a throw is retried like a raised exception" do
      run =
        run_feature(
          """
          Feature: throw retry
            @retry-1
            Scenario: throws once
              Given a step that throws the first time
          """,
          steps: [Steps]
        )

      assert %{total: 1, failures: 0, passed: 1} = run
      assert count(run.events, :throw_step) == 2
      assert run.output =~ "Cucumber: retrying scenario"
    end

    test "an exhausted exit still fails the scenario with the exit reason" do
      defmodule AlwaysExitSteps do
        use Cucumber.StepDefinition

        step "a step that always exits", _context do
          Collector.record(:always_exits)
          exit(:simulated_timeout)
        end
      end

      run =
        run_feature(
          """
          Feature: exit exhausted
            @retry-1
            Scenario: exits every time
              Given a step that always exits
          """,
          steps: [AlwaysExitSteps]
        )

      assert %{total: 1, failures: 1} = run
      assert count(run.events, :always_exits) == 2
      assert run.output =~ "simulated_timeout"
    end
  end

  describe "deterministic run-level failures" do
    defmodule FailingBeforeAllHooks do
      use Cucumber.Hooks

      before_all _context do
        Collector.record(:before_all_ran)
        raise "run-level setup went wrong"
      end
    end

    test "a failed BeforeAll is never retried — its error is cached for the run" do
      run =
        with_retry_config(2, fn ->
          run_feature(
            """
            Feature: before_all failure under retry
              Scenario: never starts
                Given a step that always passes
            """,
            steps: [Steps],
            hooks: [FailingBeforeAllHooks]
          )
        end)

      assert %{total: 1, failures: 1} = run
      assert count(run.events, :before_all_ran) == 1
      assert run.output =~ "run-level setup went wrong"
      refute :always_passes in run.events
      refute run.output =~ "Cucumber: retrying scenario"
    end
  end

  describe "attachments under retry" do
    defmodule AttachingSteps do
      use Cucumber.StepDefinition

      step "a step that attaches evidence then fails", context do
        Cucumber.attach(context, "evidence-#{context.retry_attempt}", "text/plain")
        raise "still broken"
      end
    end

    test "failure output lists only the failing attempt's attachments" do
      run =
        run_feature(
          """
          Feature: attachment retry
            @retry-1
            Scenario: attaches every attempt
              Given a step that attaches evidence then fails
          """,
          steps: [AttachingSteps]
        )

      assert %{total: 1, failures: 1} = run

      # Every attempt's attachments stay in the coordinator, attributed to
      # their attempt (each retry is its own test case for #28)...
      assert [
               %Cucumber.Attachment{body: "evidence-1", attempt: 1},
               %Cucumber.Attachment{body: "evidence-2", attempt: 2}
             ] = run.attachments

      # ...but the reported failure lists only the final attempt's, once
      refute run.output =~ "evidence-1"
      assert length(String.split(run.output, "evidence-2")) - 1 == 1
    end
  end

  describe "attempt isolation" do
    test "hooks and background re-run per attempt with a fresh context" do
      defmodule RetryHooks do
        use Cucumber.Hooks

        before_scenario context do
          Collector.record(:before_hook)
          {:ok, Map.put(context, :from_hook, true)}
        end

        after_scenario _context do
          Collector.record(:after_hook)
          :ok
        end
      end

      defmodule IsolationSteps do
        use Cucumber.StepDefinition
        import ExUnit.Assertions

        step "a background step", _context do
          Collector.record(:background_step)
          :ok
        end

        step "a step that pollutes the context then fails once", context do
          # A previous attempt's context mutation must not leak in
          refute Map.has_key?(context, :polluted)
          assert context.from_hook

          Collector.record({:attempt, context.retry_attempt})

          if Enum.count(Collector.events(), &match?({:attempt, _}, &1)) < 2 do
            _context = Map.put(context, :polluted, true)
            raise "flaky"
          end

          :ok
        end
      end

      run =
        run_feature(
          """
          Feature: isolation
            Background:
              Given a background step

            @retry-1
            Scenario: retried with fresh state
              Given a step that pollutes the context then fails once
          """,
          steps: [IsolationSteps],
          hooks: [RetryHooks]
        )

      assert %{total: 1, failures: 0, passed: 1} = run

      # Hooks and background ran once per attempt, and the context carried
      # the 1-based attempt number
      assert count(run.events, :before_hook) == 2
      assert count(run.events, :background_step) == 2
      assert count(run.events, :after_hook) == 2
      assert [{:attempt, 1}, {:attempt, 2}] = Enum.filter(run.events, &match?({:attempt, _}, &1))
    end
  end
end
