defmodule Cucumber.Behavior.CompileRunsTest do
  @moduledoc """
  Behavior tests for how compiling features joins a run: Cucumber Messages
  are on before any feature module exists (ExUnit starts an async module as
  soon as it is defined when `compile_features!/1` runs from a test file),
  and a second `compile_features!/1` call in a run adds to that run instead
  of resetting it.
  """

  use Cucumber.BehaviorCase

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
  test "an async scenario records messages before its compile call returns", %{tmp_dir: dir} do
    path = Path.join(dir, "during.ndjson")
    {output, status} = run_fixture("during_compile.exs", path)
    assert status == 0, output

    stream = envelopes(path)
    assert length(payloads(stream, "testCaseFinished")) == 2
    assert Enum.any?(payloads(stream, "attachment"), &String.starts_with?(&1["body"], "first "))
  end

  defp run_fixture(script, argument) do
    System.cmd(
      System.find_executable("elixir"),
      [
        "-pa",
        Application.app_dir(:cucumber, "ebin"),
        Path.join("test/fixtures/compile_runs", script),
        argument
      ],
      stderr_to_stdout: true
    )
  end

  @tag :tmp_dir
  test "an empty suite closes and later compile calls share a stream with paired teardown", %{
    tmp_dir: tmp_dir
  } do
    {output, status} = run_fixture("run.exs", tmp_dir)
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

    assert :ok = Cucumber.CckStream.assert_valid(joined)

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
