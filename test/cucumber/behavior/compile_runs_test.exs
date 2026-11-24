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
  test "uses every step definition module in the same file", %{tmp_dir: dir} do
    feature = dir |> Path.join("shared.feature") |> Path.relative_to_cwd()
    steps = Path.join(dir, "shared.exs")

    File.write!(feature, """
    Feature: shared file
      Scenario: first module
        Given the first definition
      Scenario: second module
        Given the second definition
    """)

    File.write!(steps, """
    defmodule SharedFile.First do
      use Cucumber.StepDefinition
      step "the first definition", _ctx do
        :ok
      end
    end

    defmodule SharedFile.Second do
      use Cucumber.StepDefinition
      step "the second definition", _ctx do
        :ok
      end
    end
    """)

    modules = Cucumber.compile_features!(features: feature, steps: steps, support: [])
    {result, output} = Cucumber.BehaviorCase.run_isolated(modules)
    assert %{total: 2, failures: 0} = result, output
  end

  @tag :tmp_dir
  test "messages are on before the first feature module is defined", %{tmp_dir: tmp_dir} do
    RunCoordinator.ensure_started()
    path = Path.join(tmp_dir, "messages.ndjson")
    previous = Application.fetch_env(:cucumber, :messages)
    Application.put_env(:cucumber, :messages, path)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:cucumber, :messages, value)
        :error -> Application.delete_env(:cucumber, :messages)
      end
    end)

    traced = [{RunCoordinator, :configure_messages, 1}, {Compiler, :compile_feature!, 4}]

    {modules, calls} =
      trace_calls(traced, fn ->
        Cucumber.compile_features!(
          features: "test/fixtures/compile_runs/*.feature",
          steps: [],
          support: []
        )
      end)

    assert calls == [
             {RunCoordinator, :configure_messages},
             {Compiler, :compile_feature!},
             {Compiler, :compile_feature!}
           ]

    {result, _output} = Cucumber.BehaviorCase.run_isolated(modules, seed: 0)
    assert result.total > 0
    assert length(payloads(envelopes(path), "testCaseFinished")) == result.total
  after
    RunCoordinator.ensure_started()
  end

  @tag :tmp_dir
  test "an empty suite closes and later compile calls share a stream with paired teardown", %{
    tmp_dir: tmp_dir
  } do
    ebin = Application.app_dir(:cucumber, "ebin")

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "-pa",
          ebin,
          "test/fixtures/compile_runs/run.exs",
          tmp_dir
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    empty = envelopes(Path.join(tmp_dir, "empty.ndjson"))
    assert payloads(empty, "testCase") == []
    assert [%{"success" => true}] = payloads(empty, "testRunFinished")

    joined = envelopes(Path.join(tmp_dir, "joined.ndjson"))
    assert [%{}] = payloads(joined, "meta")
    assert [%{"success" => true}] = payloads(joined, "testRunFinished")
    assert length(payloads(joined, "testCaseFinished")) == 2

    pickle_ids = for pickle <- payloads(joined, "pickle"), do: pickle["id"]
    cases = payloads(joined, "testCase")
    assert length(pickle_ids) == 2
    assert Enum.sort(Enum.map(cases, & &1["pickleId"])) == Enum.sort(pickle_ids)

    definitions = payloads(joined, "stepDefinition")
    assert length(definitions) == 2
    patterns = Map.new(definitions, &{&1["id"], &1["pattern"]["source"]})

    assert Enum.map(cases, fn test_case ->
             for %{"stepDefinitionIds" => [id]} <- test_case["testSteps"],
                 do: Map.fetch!(patterns, id)
           end) == [
             ["use the resource for {word}"],
             ["use the resource for {word}", "check the second resource"]
           ]

    ids =
      for key <- ~w(pickle stepDefinition hook testCase testCaseStarted testRunStarted),
          payload <- payloads(joined, key),
          do: payload["id"]

    assert ids == Enum.uniq(ids)

    bodies = for attachment <- payloads(joined, "attachment"), do: attachment["body"]
    assert ["first " <> first] = Enum.filter(bodies, &String.starts_with?(&1, "first "))
    assert ["second " <> second] = Enum.filter(bodies, &String.starts_with?(&1, "second "))
    refute first == second

    assert Enum.sort(bodies) ==
             Enum.sort([
               "acquired #{first}",
               "first #{first}",
               "released #{first}",
               "acquired #{second}",
               "second #{second}",
               "released #{second}",
               "extra cleanup #{second}"
             ])
  end
end
