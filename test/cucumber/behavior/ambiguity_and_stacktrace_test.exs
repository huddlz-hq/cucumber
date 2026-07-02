defmodule Cucumber.AmbiguityAndStacktraceTest do
  @moduledoc """
  Behavior tests for ambiguous step detection (#20) and feature-file stack
  frames (#22).
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule AmbiguousSteps do
    use Cucumber.StepDefinition

    step "a step with multiple definitions", _context do
      Collector.record(:literal_definition)
      :ok
    end

    step "a {word} with multiple definitions", _context do
      Collector.record(:parameterized_definition)
      :ok
    end

    step "a step after the ambiguous one", _context do
      Collector.record(:after_ambiguous)
      :ok
    end

    step "an unambiguous walrus with multiple definitions", _context do
      Collector.record(:unambiguous)
      :ok
    end
  end

  defmodule FailingSteps do
    use Cucumber.StepDefinition

    step "a passing step", _context do
      :ok
    end

    step "a step that raises", _context do
      raise "kaboom"
    end
  end

  describe "ambiguous step detection (CCK: ambiguous)" do
    test "a step matching two definitions fails with both patterns and their locations" do
      run =
        run_feature(
          File.read!("test/fixtures/cck/ambiguous/ambiguous.feature"),
          steps: [AmbiguousSteps]
        )

      assert %{total: 1, passed: 0, failures: 1} = run
      assert run.output =~ "Cucumber.AmbiguousStepError"
      assert run.output =~ "matches 2 step definitions"
      assert run.output =~ ~s("a step with multiple definitions")
      assert run.output =~ ~s("a {word} with multiple definitions")
      # Both definition sites are listed with file:line
      assert run.output =~ ~r/ambiguity_and_stacktrace_test\.exs:\d+/
      # Neither definition actually executed
      assert run.events == []
    end

    test "overlapping patterns are not ambiguous for a text only one of them matches" do
      # "an unambiguous walrus with multiple definitions" is matched by the
      # literal definition; "a {word} with multiple definitions" does not
      # match it (different leading article), so there is no false positive.
      run =
        run_feature(
          """
          Feature: not ambiguous
            Scenario: only one matches
              Given an unambiguous walrus with multiple definitions
          """,
          steps: [AmbiguousSteps]
        )

      assert %{total: 1, passed: 1, failures: 0} = run
      assert run.events == [:unambiguous]
    end

    test "steps after an ambiguous step do not execute" do
      run =
        run_feature(
          """
          Feature: ambiguous mid-scenario
            Scenario: stops at ambiguity
              Given a step with multiple definitions
              And a step after the ambiguous one
          """,
          steps: [AmbiguousSteps]
        )

      assert run.failures == 1
      refute :after_ambiguous in run.events
    end

    test "an ambiguous background step fails every scenario in the feature" do
      run =
        run_feature(
          """
          Feature: ambiguous background
            Background:
              Given a step with multiple definitions

            Scenario: first
              Given a step after the ambiguous one

            Scenario: second
              Given a step after the ambiguous one
          """,
          steps: [AmbiguousSteps]
        )

      assert run.total == 2
      assert run.passed == 0
      assert run.events == []
    end
  end

  describe "stack traces point at the feature file (#22)" do
    test "a failing step's first stack frame is the feature file at the step's line" do
      run =
        run_feature(
          """
          Feature: stack frames
            Scenario: failing
              Given a passing step
              And a step that raises
          """,
          steps: [FailingSteps],
          file: "test/fixtures/generated/stack_frames.feature"
        )

      assert run.failures == 1

      stacktrace_section = run.output |> String.split("stacktrace:") |> List.last()
      [first_frame, second_frame | _] = stacktrace_section |> String.split("\n", trim: true)

      # First frame: the failing step's line in the feature file
      assert first_frame =~ "test/fixtures/generated/stack_frames.feature:4"
      # Second frame: the step definition that raised
      assert second_frame =~ "ambiguity_and_stacktrace_test.exs"
      # Internal runtime frames are filtered out
      refute run.output =~ "lib/cucumber/runtime.ex"
    end

    test "a missing step's stack trace also leads with the feature file" do
      run =
        run_feature(
          """
          Feature: missing step frames
            Scenario: undefined
              Given a step nobody defined
          """,
          steps: [FailingSteps],
          file: "test/fixtures/generated/missing_frames.feature"
        )

      assert run.failures == 1

      stacktrace_section = run.output |> String.split("stacktrace:") |> List.last()
      [first_frame | _] = stacktrace_section |> String.split("\n", trim: true)

      assert first_frame =~ "test/fixtures/generated/missing_frames.feature:3"
      refute run.output =~ "lib/cucumber/runtime.ex"
    end

    test "captured output stays plain text when the outer run is on a TTY" do
      # On a TTY, Elixir enables ANSI globally and the nested run's
      # formatter would color its output, breaking every assertion that
      # parses run.output (the frame extraction above grabs an escape
      # sequence instead of the frame). Force the TTY condition
      ansi_before = Application.get_env(:elixir, :ansi_enabled, false)
      Application.put_env(:elixir, :ansi_enabled, true)

      try do
        run =
          run_feature(
            """
            Feature: plain output
              Scenario: failing
                Given a passing step
                And a step that raises
            """,
            steps: [FailingSteps],
            file: "test/fixtures/generated/plain_output.feature"
          )

        assert run.failures == 1
        refute run.output =~ "\e["

        stacktrace_section = run.output |> String.split("stacktrace:") |> List.last()
        [first_frame | _] = String.split(stacktrace_section, "\n", trim: true)
        assert first_frame =~ "test/fixtures/generated/plain_output.feature:4"
      after
        Application.put_env(:elixir, :ansi_enabled, ansi_before)
      end
    end
  end
end
