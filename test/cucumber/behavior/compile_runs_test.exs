defmodule Cucumber.Behavior.CompileRunsTest do
  @moduledoc """
  Behavior tests for how compiling features joins a run: Cucumber Messages
  are on before any feature module exists (ExUnit starts an async module as
  soon as it is defined when `compile_features!/1` runs from a test file),
  and a second `compile_features!/1` call in a run adds to that run instead
  of resetting it.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.Compiler
  alias Cucumber.RunCoordinator
  alias Cucumber.StepRegistry

  defmodule FirstSteps do
    use Cucumber.StepDefinition

    step "a first step", context do
      Collector.record({:first_step, Map.get(context, :first_setup)})
      context
    end

    step "a shared step", context do
      context
    end
  end

  defmodule SecondSteps do
    use Cucumber.StepDefinition

    step "a second step", context do
      Collector.record({:second_step, Map.get(context, :second_setup)})
      context
    end
  end

  defmodule FirstHooks do
    use Cucumber.Hooks

    before_all _context do
      Collector.record(:first_before_all)
      %{first_setup: true}
    end

    after_all _context do
      Collector.record(:first_after_all)
      :ok
    end
  end

  defmodule SecondHooks do
    use Cucumber.Hooks

    before_all _context do
      Collector.record(:second_before_all)
      %{second_setup: true}
    end

    after_all _context do
      Collector.record(:second_after_all)
      :ok
    end
  end

  @first_feature """
  Feature: First
    Scenario: first
      Given a first step
      And a shared step
  """

  @second_feature """
  Feature: Second
    Scenario: second
      Given a second step
      And a shared step
  """

  defp features(sources) do
    for source <- List.wrap(sources) do
      file = "test/fixtures/generated/compile_runs_#{System.unique_integer([:positive])}.feature"
      source |> Gherkin.Parser.parse(file) |> Map.put(:file, file) |> Map.put(:source, source)
    end
  end

  # Runs `fun` with calls to the `traced` functions traced, returning its
  # result and the calls in order. Trace messages go to a separate
  # collector process.
  defp trace_calls(traced, fun) do
    collector = spawn_link(fn -> collect_traced_calls([]) end)
    Enum.each(traced, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(self(), true, [:call, {:tracer, collector}])

    result =
      try do
        fun.()
      after
        :erlang.trace(self(), false, [:call])
        Enum.each(traced, &:erlang.trace_pattern(&1, false, [:local]))
      end

    ref = :erlang.trace_delivered(self())
    receive do: ({:trace_delivered, _pid, ^ref} -> :ok)
    send(collector, {:calls, self()})
    receive do: ({:traced_calls, calls} -> {result, calls})
  end

  defp collect_traced_calls(calls) do
    receive do
      {:trace, _pid, :call, {module, function, _args}} ->
        collect_traced_calls([{module, function} | calls])

      {:calls, from} ->
        send(from, {:traced_calls, Enum.reverse(calls)})
    end
  end

  defp envelopes(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp payloads(envelopes, key), do: for(%{^key => payload} <- envelopes, do: payload)

  @tag :tmp_dir
  test "messages are on before the first feature module is defined", %{tmp_dir: tmp_dir} do
    RunCoordinator.ensure_started()
    path = Path.join(tmp_dir, "messages.ndjson")
    traced = [{RunCoordinator, :configure_messages, 1}, {Compiler, :compile_feature!, 4}]

    {modules, calls} =
      trace_calls(traced, fn ->
        Compiler.compile_all!(
          features([@first_feature, @second_feature]),
          StepRegistry.new([FirstSteps, SecondSteps]),
          [],
          path
        )
      end)

    assert calls == [
             {RunCoordinator, :configure_messages},
             {Compiler, :compile_feature!},
             {Compiler, :compile_feature!}
           ]

    {result, _output} = Cucumber.BehaviorCase.run_isolated(modules, seed: 0)
    assert %{total: 2, failures: 0} = result
    assert length(payloads(envelopes(path), "testCaseFinished")) == 2
  after
    RunCoordinator.ensure_started()
  end

  @tag :tmp_dir
  test "a second compile_features! call joins the run in progress", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "messages.ndjson")
    run_id = RunCoordinator.ensure_started()
    Collector.reset()

    first =
      Compiler.compile_all!(
        features(@first_feature),
        StepRegistry.new([FirstSteps]),
        [FirstHooks],
        path
      )

    assert RunCoordinator.start_or_join() == run_id

    second =
      Compiler.compile_all!(
        features(@second_feature),
        StepRegistry.new([FirstSteps, SecondSteps]),
        [SecondHooks],
        path
      )

    {result, _output} = Cucumber.BehaviorCase.run_isolated(first ++ second, seed: 0)
    assert %{total: 2, failures: 0} = result

    # Each call's before_all hooks ran once and set up its own scenarios;
    # every after_all hook ran
    events = Collector.events()
    assert Enum.count(events, &(&1 == :first_before_all)) == 1
    assert Enum.count(events, &(&1 == :second_before_all)) == 1
    assert {:first_step, true} in events
    assert {:second_step, true} in events
    assert :first_after_all in events
    assert :second_after_all in events

    # One stream with both calls' features and test cases
    envelopes = envelopes(path)
    assert length(payloads(envelopes, "meta")) == 1
    assert length(payloads(envelopes, "pickle")) == 2
    assert length(payloads(envelopes, "testCaseFinished")) == 2
    assert [%{"success" => true}] = payloads(envelopes, "testRunFinished")

    # The shared step definition is listed once, and every id is run-unique
    step_definitions = payloads(envelopes, "stepDefinition")
    assert length(step_definitions) == 3

    ids =
      for key <- ~w(pickle stepDefinition hook testCase testCaseStarted testRunStarted),
          payload <- payloads(envelopes, key),
          do: payload["id"]

    assert ids == Enum.uniq(ids)

    definition_ids = MapSet.new(step_definitions, & &1["id"])

    for test_case <- payloads(envelopes, "testCase"),
        test_step <- test_case["testSteps"],
        id <- Map.get(test_step, "stepDefinitionIds", []),
        do: assert(id in definition_ids)

    # The suite ending ends the run: the next compile starts a fresh one
    refute RunCoordinator.start_or_join() == run_id
  after
    RunCoordinator.ensure_started()
  end
end
