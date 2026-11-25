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
  test "mix test repetitions reuse compiled modules with fresh hooks and Messages", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "test"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule RepeatFixture.MixProject do
      use Mix.Project
      def project, do: [app: :repeat_fixture, version: "0.1.0", prune_code_paths: false]
    end
    """)

    File.write!(Path.join(dir, "test/test_helper.exs"), """
    ExUnit.start()
    Application.put_env(:cucumber, :messages, "repeat.ndjson")
    Cucumber.compile_features!(features: "repeat.feature", steps: "steps.exs", support: "steps.exs")
    """)

    File.write!(
      Path.join(dir, "test/repeat_test.exs"),
      "# Tests are generated from repeat.feature.\n"
    )

    File.write!(
      Path.join(dir, "repeat.feature"),
      "Feature: repeat\n  Scenario: one\n    Given use the resource\n"
    )

    File.write!(Path.join(dir, "steps.exs"), """
    defmodule RepeatFixture.Steps do
      use Cucumber.StepDefinition
      use Cucumber.Hooks

      before_all _ctx do
        id = Integer.to_string(System.unique_integer([:positive]))
        File.write!("events", "acquire " <> id <> "\\n", [:append])
        %{resource: id}
      end

      step "use the resource", ctx do
        File.write!("events", "use " <> ctx.resource <> "\\n", [:append])
        Cucumber.log(ctx, ctx.resource)
      end

      after_all ctx do
        File.write!("events", "release " <> ctx.resource <> "\\n", [:append])
      end
    end
    """)

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "-pa",
          Application.app_dir(:cucumber, "ebin"),
          "-S",
          "mix",
          "test",
          "--repeat-until-failure",
          "2"
        ],
        cd: dir,
        stderr_to_stdout: true
      )

    assert status == 0, output
    events = dir |> Path.join("events") |> File.read!() |> String.split("\n", trim: true)

    assert length(events) == 9

    ids =
      for ["acquire " <> id, used, released] <- Enum.chunk_every(events, 3) do
        assert used == "use " <> id
        assert released == "release " <> id
        id
      end

    assert length(ids) == 3
    assert ids == Enum.uniq(ids)
    stream = envelopes(Path.join(dir, "repeat.ndjson"))
    assert :ok = Cucumber.CckStream.assert_valid(stream)
    assert [%{"body" => last}] = payloads(stream, "attachment")
    assert last == List.last(ids)
  end

  defmodule LifetimeSteps do
    use Cucumber.StepDefinition

    step "use this run", _context do
      Collector.record(:ran)
      :ok
    end
  end

  test "a compiled module expires after teardown and recompiling permits a fresh run" do
    source = """
    Feature: resources
      Scenario: lifetime
        Given use this run
    """

    first = run_feature(source, steps: [LifetimeSteps])
    assert first.passed == 1
    assert first.events == [:ran]

    {expired, output} = Cucumber.BehaviorCase.run_isolated(first.modules)
    assert %{total: 1, failures: 1} = expired
    assert output =~ "Call Cucumber.compile_features!/1 again"
    assert Collector.events() == [:ran]

    fresh = run_feature(source, steps: [LifetimeSteps])
    assert fresh.passed == 1
    assert fresh.events == [:ran]
  end

  @tag :tmp_dir
  test "joined compile calls cannot replace a previously registered feature", %{tmp_dir: dir} do
    plain = Path.join(dir, "checkout.feature") |> Path.relative_to_cwd()
    markdown = plain <> ".md"
    File.write!(plain, "Feature: Checkout\n  Scenario: plain checkout\n")
    File.write!(markdown, "# Feature: Checkout\n## Scenario: markdown checkout\n")
    compile = fn path -> Cucumber.compile_features!(features: path, steps: [], support: []) end

    [original] = compile.(plain)

    error = assert_raise ArgumentError, fn -> compile.(markdown) end
    assert error.message =~ plain
    assert error.message =~ markdown
    assert error.message =~ Atom.to_string(original)
    assert [%{name: :"test plain checkout"}] = original.__ex_unit__().tests

    {result, output} = Cucumber.BehaviorCase.run_isolated([original])
    assert %{total: 1, failures: 0} = result, output
    ExUnit.CaptureIO.capture_io(:stderr, fn -> assert [^original] = compile.(markdown) end)
    assert [%{name: :"test markdown checkout"}] = original.__ex_unit__().tests
    {result, output} = Cucumber.BehaviorCase.run_isolated([original])
    assert %{total: 1, failures: 0} = result, output
  end

  @tag :tmp_dir
  test "a failed batch keeps its defined modules and releases the unfinished names", %{
    tmp_dir: dir
  } do
    [first, broken, last] =
      Enum.map(~w(a b c), fn name ->
        Path.join(dir, name <> ".feature") |> Path.relative_to_cwd()
      end)

    valid = "Feature: retry\n  Scenario: succeeds\n"
    File.write!(first, valid)
    File.write!(broken, valid <> "  Scenario: succeeds\n")
    File.write!(last, valid)
    compile = fn paths -> Cucumber.compile_features!(features: paths, steps: [], support: []) end

    assert_raise ArgumentError, ~r/is already defined/, fn -> compile.([first, broken, last]) end
    assert_raise ArgumentError, ~r/already registered/, fn -> compile.(first) end
    File.write!(broken, valid)
    modules = compile.([broken, last])
    {result, output} = Cucumber.BehaviorCase.run_isolated(modules)
    assert %{total: 3, failures: 0} = result, output
  end

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
    assert :ok = Cucumber.CckStream.assert_valid(stream)

    assert Enum.any?(payloads(stream, "attachment"), fn attachment ->
             String.starts_with?(attachment["body"], "first ") and
               is_binary(attachment["testCaseStartedId"]) and is_binary(attachment["testStepId"])
           end)
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
