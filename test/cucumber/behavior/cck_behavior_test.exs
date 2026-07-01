defmodule Cucumber.CckBehaviorTest do
  @moduledoc """
  Behavior tests driven by vendored Cucumber Compatibility Kit samples
  (`test/fixtures/cck/`). Each test runs a CCK feature against Elixir step
  definitions equivalent to the kit's reference TypeScript step definitions
  and asserts the outcome the reference implementation produces.

  Samples for behaviors this implementation does not support correctly yet
  (ambiguous, pending, skipped, retry, attachments, hooks variants, rules...)
  are added by the issues that implement them — see issues #17–#29.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule MinimalSteps do
    use Cucumber.StepDefinition

    step "I have {int} cukes in my belly", _context do
      :ok
    end
  end

  defmodule CdataSteps do
    use Cucumber.StepDefinition

    step "I have {int} <![CDATA[cukes]]> in my belly", _context do
      :ok
    end
  end

  defmodule DataTableSteps do
    use Cucumber.StepDefinition
    import ExUnit.Assertions

    step "the following table is transposed:", context do
      transposed =
        context.datatable.raw
        |> Enum.zip()
        |> Enum.map(&Tuple.to_list/1)

      %{transposed: transposed}
    end

    step "it should be:", context do
      assert context.transposed == context.datatable.raw
      :ok
    end
  end

  defmodule BackgroundSteps do
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

  defmodule ExamplesTableSteps do
    use Cucumber.StepDefinition
    import ExUnit.Assertions

    step "there are {int} cucumbers", %{args: [count]} do
      %{count: count}
    end

    step "there are {int} friends", %{args: [friends]} do
      %{friends: friends}
    end

    step "I eat {int} cucumbers", %{args: [eat]} = context do
      %{count: context.count - eat}
    end

    step "I should have {int} cucumbers", %{args: [expected]} = context do
      assert context.count == expected
      :ok
    end

    step "each person can eat {int} cucumbers", %{args: [expected]} = context do
      share = div(context.count, 1 + context.friends)
      assert share == expected
      :ok
    end
  end

  defmodule UndefinedSteps do
    use Cucumber.StepDefinition

    step "an implemented step", _context do
      :ok
    end

    step "a step that will be skipped", _context do
      :ok
    end
  end

  defmodule HookSteps do
    use Cucumber.StepDefinition

    step "a step passes", _context do
      Collector.record(:step_passes)
      :ok
    end

    step "a step fails", _context do
      Collector.record(:step_fails)
      raise "Exception in step"
    end
  end

  defmodule HookHooks do
    use Cucumber.Hooks

    before_scenario context do
      Collector.record(:before)
      {:ok, context}
    end

    after_scenario _context do
      Collector.record(:after)
      :ok
    end
  end

  defmodule DocStringSteps do
    use Cucumber.StepDefinition

    step "a doc string:", context do
      Collector.record({:docstring, context.docstring, context[:docstring_media_type]})
      :ok
    end
  end

  defmodule StackTraceSteps do
    use Cucumber.StepDefinition

    step "a step throws an exception", _context do
      raise "BOOM"
    end
  end

  defmodule UnusedSteps do
    use Cucumber.StepDefinition

    step "a step that is used", _context do
      :ok
    end

    step "a step that is not used", _context do
      :ok
    end
  end

  describe "CCK: minimal" do
    test "the single scenario passes" do
      run = run_feature(fixture("minimal"), steps: [MinimalSteps])

      assert %{total: 1, passed: 1, failures: 0} = run
    end
  end

  describe "CCK: cdata" do
    test "a step containing an XML CDATA section matches and passes" do
      run = run_feature(fixture("cdata"), steps: [CdataSteps])

      assert %{total: 1, passed: 1, failures: 0} = run
    end
  end

  describe "CCK: empty" do
    test "a scenario with no steps passes" do
      run = run_feature(fixture("empty"), steps: [])

      assert %{total: 1, passed: 1, failures: 0} = run
    end
  end

  describe "CCK: data-tables" do
    test "a table can be transposed and compared" do
      run = run_feature(fixture("data-tables"), steps: [DataTableSteps])

      assert %{total: 1, passed: 1, failures: 0} = run
    end
  end

  describe "CCK: backgrounds" do
    test "background steps run before each scenario's own steps" do
      run = run_feature(fixture("backgrounds"), steps: [BackgroundSteps])

      assert %{total: 2, passed: 2, failures: 0} = run

      # Each scenario sees the three background orders, then action, outcome.
      expected_scenario_events = [
        {:order, "eggs"},
        {:order, "milk"},
        {:order, "bread"},
        :action,
        :outcome
      ]

      assert Enum.chunk_every(run.events, 5) == [
               expected_scenario_events,
               expected_scenario_events
             ]
    end
  end

  describe "CCK: examples-tables" do
    test "passing rows pass and @failing rows fail" do
      run = run_feature(fixture("examples-tables"), steps: [ExamplesTableSteps])

      # Outline 1: 2 passing rows + 2 failing rows; outline 2: 3 passing rows.
      assert %{total: 7, passed: 5, failures: 2} = run
      assert run.output =~ "Assertion with == failed"
    end
  end

  describe "CCK: undefined" do
    test "every scenario with an undefined step fails, and suggestions reflect parameter types" do
      run = run_feature(fixture("undefined"), steps: [UndefinedSteps])

      assert %{total: 4, passed: 0, failures: 4} = run
      assert run.output =~ "No matching step definition found"
      # CCK: "Snippets reflect parameter types" — 8 must become {int}
      assert run.output =~ ~s(step "a list of {int} things")
    end

    test "steps before an undefined step execute; steps after it do not" do
      run =
        run_feature(fixture("undefined"),
          steps: [UndefinedSteps],
          hooks: []
        )

      # "Steps before undefined steps are executed" ran its implemented step,
      # while "Steps after undefined steps are skipped" never reached its
      # implemented step. Both error messages quote the undefined step text.
      assert run.output =~ "a step that is yet to be defined"
    end
  end

  describe "CCK: hooks" do
    test "hooks bracket both passing and failing scenarios" do
      run = run_feature(fixture("hooks"), steps: [HookSteps], hooks: [HookHooks])

      assert %{total: 2, passed: 1, failures: 1} = run
      assert run.output =~ "Exception in step"

      # Two scenarios, each bracketed: before ... after, regardless of outcome.
      assert Enum.count(run.events, &(&1 == :before)) == 2
      assert Enum.count(run.events, &(&1 == :after)) == 2

      assert Enum.chunk_every(run.events, 3)
             |> Enum.all?(fn [b, _step, a] ->
               b == :before and a == :after
             end)
    end
  end

  describe "CCK: doc-strings" do
    test "standard, backtick, and media-typed docstrings all reach the step" do
      run = run_feature(fixture("doc-strings"), steps: [DocStringSteps])

      assert %{total: 3, passed: 3, failures: 0} = run

      # Scenario order within the nested run depends on the seed, so assert
      # on the collected set rather than sequence.
      contents = for {:docstring, content, _media} <- run.events, do: content
      medias = for {:docstring, _content, media} <- run.events, do: media

      assert Enum.count(contents, &(&1 == "Here is some content\nAnd some more on another line")) ==
               2

      assert Enum.count(medias, &is_nil/1) == 2
      assert "application/json" in medias
      assert Enum.any?(contents, &(&1 =~ ~s("foo": "bar")))
    end
  end

  describe "CCK: hooks-skipped (parse-only until skip semantics land)" do
    test "the feature with scenario descriptions parses and undefined skip steps fail" do
      # Full skip behavior arrives with issue #21; today this fixture proves
      # the parser handles its scenario descriptions (issue #17) and the
      # undefined skip steps fail rather than silently pass.
      run = run_feature(fixture("hooks-skipped"), steps: [])

      assert run.total == 3
      assert run.failures == 3
      assert run.output =~ "No matching step definition found"
    end
  end

  describe "CCK: stack-traces" do
    test "a step that throws fails with the exception message and a feature-file stack frame" do
      run =
        run_feature(fixture("stack-traces"),
          steps: [StackTraceSteps],
          file: "test/fixtures/cck/stack-traces/stack-traces.feature"
        )

      assert %{total: 1, passed: 0, failures: 1} = run
      assert run.output =~ "BOOM"

      # CCK: the first line of the stack trace references the feature file
      stacktrace_section = run.output |> String.split("stacktrace:") |> List.last()
      [first_frame | _] = String.split(stacktrace_section, "\n", trim: true)
      assert first_frame =~ "stack-traces.feature:10"
    end
  end

  describe "CCK: unused-steps" do
    test "unused step definitions are valid and do not affect the run" do
      run = run_feature(fixture("unused-steps"), steps: [UnusedSteps])

      assert %{total: 1, passed: 1, failures: 0} = run
    end
  end
end
