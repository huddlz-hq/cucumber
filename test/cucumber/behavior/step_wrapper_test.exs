defmodule Cucumber.Behavior.StepWrapperTest do
  @moduledoc """
  Behavior tests for `config :cucumber, step_wrapper: {module, function}`:
  the function runs around every executed step and sees its outcome.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule Wrapper do
    def wrap(step, context, run) do
      Collector.record({:wrap, step, context.scenario_name})

      try do
        result = run.()
        Collector.record({:outcome, step.text, outcome(result)})
        result
      rescue
        error ->
          Collector.record({:raised, step.text, error.__struct__})
          reraise error, __STACKTRACE__
      end
    end

    defp outcome(%{} = _context), do: :passed
    defp outcome({:halted, status, reason, %{}}), do: {status, reason}
  end

  # Wrappers that bend or break the contract in "Step Wrapper" (docs/hooks.md)
  defmodule OddWrapper do
    def return_own_context(_step, context, run) do
      run.()
      context
    end

    def raise_before_run(_step, _context, _run), do: raise("tracer down")

    def raise_first_attempt(_step, %{retry_attempt: 1}, _run), do: raise("tracer down")
    def raise_first_attempt(_step, context, run), do: run.() && context

    def raise_after_run(_step, _context, run) do
      run.()
      raise "tracer down"
    end

    def skip_run(_step, context, _run), do: context

    def erase_dictionary(_step, context, run) do
      run.()
      Enum.each(Process.get_keys(), &Process.delete/1)
      context
    end

    def run_twice(_step, context, run) do
      run.()

      try do
        run.()
      rescue
        error -> Collector.record({:second_run, Exception.message(error)})
      end

      context
    end

    def run_elsewhere(_step, context, run) do
      {pid, monitor} =
        spawn_monitor(fn ->
          try do
            run.()
          rescue
            error -> Collector.record({:elsewhere, Exception.message(error)})
          end
        end)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      end

      context
    end

    def swallow_raise(_step, context, run) do
      run.()
    rescue
      _error -> context
    end
  end

  defmodule AttachingWrapper do
    def wrap(_step, context, run) do
      Cucumber.attach(context, "from the wrapper", "text/plain")
      run.()
    end
  end

  defmodule Steps do
    use Cucumber.StepDefinition

    step "a passing step", _context do
      Collector.record(:passing_step)
      :ok
    end

    step "a failing step", _context do
      raise "boom"
    end

    step "a step that stores a value", _context do
      %{stored: :value}
    end

    step "the stored value is there", context do
      Collector.record({:stored, context[:stored]})
      :ok
    end

    step "a pending step", _context do
      {:pending, "not yet"}
    end

    step "a skipped step", _context do
      {:skipped, "not today"}
    end

    step "a step that passes the second time", _context do
      Collector.record(:second_time)

      if Enum.count(Collector.events(), &(&1 == :second_time)) < 2 do
        raise "fails the first attempt"
      end

      :ok
    end
  end

  defp with_step_wrapper(wrapper, fun) do
    previous = Application.fetch_env(:cucumber, :step_wrapper)
    Application.put_env(:cucumber, :step_wrapper, wrapper)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:cucumber, :step_wrapper, value)
        :error -> Application.delete_env(:cucumber, :step_wrapper)
      end
    end
  end

  defp run_wrapped(source) do
    with_step_wrapper({Wrapper, :wrap}, fn -> run_feature(source, steps: [Steps]) end)
  end

  defp run_with(wrapper, source, opts \\ []) do
    with_step_wrapper(wrapper, fn -> run_feature(source, [steps: [Steps]] ++ opts) end)
  end

  defp messages_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "cucumber_step_wrapper_#{System.unique_integer([:positive])}.ndjson"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp payloads(messages, type), do: for(%{^type => payload} <- messages, do: payload)

  @retried_passing_step """
  Feature: broken wrapper
    @retry-1
    Scenario: one step
      Given a passing step
  """

  defp wrapped(events), do: for({:wrap, step, _} <- events, do: step)

  test "the wrapper runs around each step, background steps included, in order" do
    run =
      run_wrapped("""
      Feature: wrapped
        Background:
          Given a passing step

        Scenario: two steps
          When a passing step
          Then a passing step
      """)

    assert run.passed == 1

    assert wrapped(run.events) == [
             %{keyword: "Given", text: "a passing step", line: 3},
             %{keyword: "When", text: "a passing step", line: 6},
             %{keyword: "Then", text: "a passing step", line: 7}
           ]

    assert [{:wrap, _, "two steps"}, :passing_step, {:outcome, "a passing step", :passed} | _] =
             run.events
  end

  test "a failing step raises its StepError through the wrapper" do
    run =
      run_wrapped("""
      Feature: wrapped
        Scenario: fails
          Given a failing step
          Then a passing step
      """)

    assert run.failures == 1
    assert run.output =~ "boom"

    assert run.events == [
             {:wrap, %{keyword: "Given", text: "a failing step", line: 3}, "fails"},
             {:raised, "a failing step", Cucumber.StepError}
           ]
  end

  test "an undefined step raises through the wrapper" do
    run =
      run_wrapped("""
      Feature: wrapped
        Scenario: undefined
          Given a step nobody defined
      """)

    assert run.failures == 1
    assert [{:wrap, _, _}, {:raised, "a step nobody defined", Cucumber.StepError}] = run.events
  end

  test "pending and skipped outcomes reach the wrapper as halts" do
    pending =
      run_wrapped("""
      Feature: wrapped
        Scenario: pending
          Given a pending step
          Then a passing step
      """)

    assert pending.failures == 1
    assert {:outcome, "a pending step", {:pending, "not yet"}} in pending.events
    assert length(wrapped(pending.events)) == 1

    skipped =
      run_wrapped("""
      Feature: wrapped
        Scenario: skipped
          Given a skipped step
      """)

    assert skipped.failures == 0
    assert {:outcome, "a skipped step", {:skipped, "not today"}} in skipped.events
  end

  test "retries call the wrapper once per step per attempt" do
    run =
      run_wrapped("""
      Feature: wrapped
        @retry-1
        Scenario: flaky
          Given a step that passes the second time
      """)

    assert run.passed == 1

    assert [
             {:raised, "a step that passes the second time", Cucumber.StepError},
             {:outcome, "a step that passes the second time", :passed}
           ] = Enum.filter(run.events, &(elem_tag(&1) in [:raised, :outcome]))
  end

  test "without a step wrapper, steps run unwrapped" do
    run =
      run_feature(
        """
        Feature: unwrapped
          Scenario: one step
            Given a passing step
        """,
        steps: [Steps]
      )

    assert run.passed == 1
    assert run.events == [:passing_step]
  end

  test "a step wrapper that isn't a {module, function} tuple fails the scenario" do
    run =
      with_step_wrapper(&Wrapper.wrap/3, fn ->
        run_feature("Feature: bad\n  Scenario: one\n    Given a passing step\n", steps: [Steps])
      end)

    assert run.failures == 1
    assert run.output =~ ":step_wrapper must be a {module, function} tuple"
  end

  test "an invalid step wrapper fails the scenario before any message for it" do
    run =
      with_step_wrapper(&Wrapper.wrap/3, fn ->
        run_feature("Feature: bad\n  Scenario: one\n    Given a passing step\n",
          steps: [Steps],
          messages: messages_path()
        )
      end)

    assert run.failures == 1
    assert payloads(run.messages, "testCase") == []
    assert payloads(run.messages, "testCaseStarted") == []
  end

  test "an undefined step wrapper function fails with an ArgumentError, unretried" do
    for wrapper <- [{Wrapper, :wrapp}, {Cucumber.NoSuchWrapper, :wrap}] do
      run = run_with(wrapper, @retried_passing_step)

      assert run.failures == 1
      assert run.output =~ "ArgumentError"

      assert run.output =~
               "#{inspect(elem(wrapper, 0))}.#{elem(wrapper, 1)}/3, which is not defined"

      refute run.output =~ "retrying"
      assert run.events == []
    end
  end

  test "the wrapper's return value is ignored: the step's result comes from run" do
    run =
      run_with({OddWrapper, :return_own_context}, """
      Feature: odd wrapper
        Scenario: two steps
          Given a step that stores a value
          Then the stored value is there
      """)

    assert run.passed == 1
    assert run.events == [{:stored, :value}]
  end

  test "a wrapper swallowing run's raise still fails the step with it" do
    run =
      run_with({OddWrapper, :swallow_raise}, """
      Feature: odd wrapper
        Scenario: fails
          Given a failing step
          Then a passing step
      """)

    assert run.failures == 1
    assert run.output =~ "Cucumber.StepError"
    assert run.output =~ "boom"
    refute run.output =~ "StepWrapperError"
    assert run.events == []
  end

  # Each contract break fails the step (FAILED in Messages) with a
  # StepWrapperError, once: it is never retried. A raise from the wrapper
  # itself is retried like its cause (see the retry tests below).
  defp assert_wrapper_failure(run, message) do
    assert run.failures == 1
    assert run.output =~ "Cucumber.StepWrapperError"
    assert run.output =~ message
    refute run.output =~ "retrying"

    assert [%{"testStepResult" => %{"status" => "FAILED", "message" => reported}}] =
             payloads(run.messages, "testStepFinished")

    assert reported =~ message
  end

  defp run_broken(function) do
    run_with({OddWrapper, function}, @retried_passing_step, messages: messages_path())
  end

  test "a wrapper raising before run fails the step with the raise as its cause" do
    run =
      run_with(
        {OddWrapper, :raise_before_run},
        "Feature: x\n  Scenario: one\n    Given a passing step\n"
      )

    assert run.failures == 1
    assert run.output =~ "the step_wrapper raised before calling run"
    assert run.output =~ "tracer down"
    assert run.events == []
  end

  test "a wrapper raising before run is retried like its cause, and can pass" do
    run = run_broken(:raise_first_attempt)

    assert run.failures == 0
    assert run.passed == 1
    assert run.events == [:passing_step]
  end

  test "a wrapper raising after run returned is retried like its cause" do
    run = run_broken(:raise_after_run)

    assert run.failures == 1
    assert run.output =~ "the step_wrapper raised after run returned"
    assert run.output =~ "tracer down"
    assert run.output =~ "retrying"
    assert run.events == [:passing_step, :passing_step]
  end

  test "a wrapper returning without calling run fails the step" do
    run = run_broken(:skip_run)

    assert_wrapper_failure(run, "the step_wrapper returned without calling run")
    assert run.events == []
  end

  test "a second call to run raises at once and fails the step" do
    run = run_broken(:run_twice)

    assert_wrapper_failure(run, "the step_wrapper called run more than once")

    assert run.events == [
             :passing_step,
             {:second_run, "the step_wrapper called run more than once"}
           ]
  end

  test "a wrapper failure points at the step's line in the feature file" do
    for function <- [:skip_run, :run_twice, :raise_before_run, :raise_after_run] do
      run = run_broken(function)

      assert run.output =~ ~r/behavior_\d+\.feature:4/
      refute run.output =~ "lib/cucumber/runtime.ex"
    end
  end

  test "a wrapper that erases the process dictionary fails the step" do
    run = run_broken(:erase_dictionary)

    assert_wrapper_failure(run, "the step_wrapper lost run's state")
    assert run.output =~ ~r/behavior_\d+\.feature:4/
  end

  test "run called from another process raises there and fails the step" do
    run = run_broken(:run_elsewhere)

    assert_wrapper_failure(run, "the step_wrapper returned without calling run")
    assert run.events == [{:elsewhere, "the step_wrapper called run outside the step's process"}]
  end

  test "attachments the wrapper records belong to the step" do
    run =
      run_with(
        {AttachingWrapper, :wrap},
        "Feature: attach\n  Scenario: one\n    Given a passing step\n",
        messages: messages_path()
      )

    assert run.passed == 1
    assert [%Cucumber.Attachment{step_text: "a passing step", phase: :step}] = run.attachments

    [%{"testStepId" => step_id}] = payloads(run.messages, "attachment")
    assert [%{"testStepId" => ^step_id}] = payloads(run.messages, "testStepFinished")
  end

  test "execute_step/3 calls the step wrapper" do
    registry = Cucumber.StepRegistry.new([Steps])
    step = %Gherkin.Step{keyword: "Given", text: "a passing step", line: 4}

    result =
      with_step_wrapper({Wrapper, :wrap}, fn ->
        Cucumber.Runtime.execute_step(%{scenario_name: "direct"}, step, registry)
      end)

    assert %{scenario_name: "direct"} = result

    assert Collector.events() == [
             {:wrap, %{keyword: "Given", text: "a passing step", line: 5}, "direct"},
             :passing_step,
             {:outcome, "a passing step", :passed}
           ]
  end

  test "a StepWrapperError carries the wrapper's own raise as its cause" do
    registry = Cucumber.StepRegistry.new([Steps])
    step = %Gherkin.Step{keyword: "Given", text: "a passing step", line: 4}

    error =
      with_step_wrapper({OddWrapper, :raise_before_run}, fn ->
        assert_raise Cucumber.StepWrapperError, fn ->
          Cucumber.Runtime.execute_step(%{scenario_name: "direct"}, step, registry)
        end
      end)

    assert %RuntimeError{message: "tracer down"} = error.cause
  end

  test "a step without a line still fails with a StepWrapperError" do
    registry = Cucumber.StepRegistry.new([Steps])
    step = %Gherkin.Step{keyword: "Given", text: "a passing step", line: nil}

    with_step_wrapper({OddWrapper, :skip_run}, fn ->
      assert_raise Cucumber.StepWrapperError, ~r/returned without calling run/, fn ->
        Cucumber.Runtime.execute_step(%{scenario_name: "direct"}, step, registry)
      end
    end)
  end

  # Two feature sets compiled by separate compile_features!/1 calls; returns
  # the scenarios the wrapper saw
  defp compile_two_sets(first_opts, second_opts) do
    # Relative, so the generated module names stay valid aliases
    n = System.unique_integer([:positive])
    dir = "tmp/step_wrapper_#{n}"
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    steps = Path.join(dir, "steps.exs")

    File.write!(steps, """
    defmodule Cucumber.Behavior.StepWrapperTest.FileSteps#{n} do
      use Cucumber.StepDefinition
      step "a passing step", _context, do: :ok
    end
    """)

    modules =
      for {name, opts} <- [first: first_opts, second: second_opts] do
        feature = Path.join(dir, "#{name}.feature")
        File.write!(feature, "Feature: #{name}\n  Scenario: #{name}\n    Given a passing step\n")
        Cucumber.compile_features!([features: feature, steps: steps, support: []] ++ opts)
      end

    modules = List.flatten(modules)

    on_exit(fn ->
      for module <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    Collector.reset()
    {result, output} = Cucumber.BehaviorCase.run_isolated(modules)
    assert %{total: 2, failures: 0} = result, output
    for {:wrap, _step, scenario} <- Collector.events(), do: scenario
  end

  test "compile_features!/1's :step_wrapper option wraps only that call's features" do
    assert compile_two_sets([step_wrapper: {Wrapper, :wrap}], []) == ["first"]
  end

  test "compile_features!/1 falls back to the app env, and the option wins" do
    wrapped =
      with_step_wrapper({Wrapper, :wrap}, fn ->
        compile_two_sets([], step_wrapper: nil)
      end)

    assert wrapped == ["first"]
  end

  defp elem_tag(event) when is_tuple(event), do: elem(event, 0)
  defp elem_tag(event), do: event
end
