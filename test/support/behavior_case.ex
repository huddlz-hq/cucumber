defmodule Cucumber.BehaviorCase do
  @moduledoc """
  Test-case template for behavior-level tests of the Cucumber pipeline.

  A behavior test expresses: *this feature source, run against these step
  definition modules, produces exactly this outcome* — including failing,
  undefined, and otherwise broken scenarios that can never live in the live
  `test/features/` suite.

  `run_feature/2` pushes the source through the real pipeline
  (`Gherkin.Parser` → `Cucumber.Compiler` → `Code.compile_quoted`) and executes
  the generated module in a nested `ExUnit.run/1`, capturing its output.

  ## Usage

      defmodule MyBehaviorTest do
        use Cucumber.BehaviorCase

        defmodule Steps do
          use Cucumber.StepDefinition

          step "a passing step", _context do
            Cucumber.BehaviorCase.Collector.record(:passing_step)
            :ok
          end
        end

        test "a passing scenario passes" do
          run =
            run_feature(
              \"\"\"
              Feature: demo
                Scenario: ok
                  Given a passing step
              \"\"\",
              steps: [Steps]
            )

          assert run.passed == 1
          assert run.events == [:passing_step]
        end
      end

  ## Constraints

  Test modules using this template **must be synchronous** — never pass
  `async: true`. The nested run temporarily swaps ExUnit's global
  include/exclude filters; by the time sync test modules execute, all async
  modules in the outer suite have already finished, so the swap cannot affect
  other tests. That guarantee does not hold for async modules.
  """

  use ExUnit.CaseTemplate

  import ExUnit.CaptureIO

  using do
    quote do
      import Cucumber.BehaviorCase,
        only: [
          run_feature: 1,
          run_feature: 2,
          run_features: 1,
          run_features: 2,
          fixture: 1,
          fixture: 2,
          count: 2
        ]

      alias Cucumber.BehaviorCase.Collector
    end
  end

  defmodule Collector do
    @moduledoc """
    Global event collector for behavior tests.

    Step definitions and hooks record events with `record/1`; the harness
    resets it before each `run_feature/2` and returns the collected events in
    the result. A single named Agent is safe because behavior tests are
    synchronous and runs never overlap.
    """

    def reset do
      case Agent.start(fn -> [] end, name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> Agent.update(__MODULE__, fn _ -> [] end)
      end
    end

    def record(event), do: Agent.update(__MODULE__, &[event | &1])

    def events, do: Agent.get(__MODULE__, &Enum.reverse/1)
  end

  # Tests that drive Cucumber.Runtime directly (bypassing run_feature/2)
  # still need the Collector running; without this, whether it exists
  # depends on which test the seed ordered first.
  setup do
    Collector.reset()
    :ok
  end

  @doc """
  Compiles and runs a Gherkin feature source against the given step modules.

  ## Options

    * `:steps` - list of modules defined with `use Cucumber.StepDefinition`
    * `:hooks` - list of modules defined with `use Cucumber.Hooks`
    * `:parameter_types` - list of modules defined with
      `use Cucumber.ParameterTypes`
    * `:file` - synthetic feature path (defaults to a unique generated path,
      which also keeps generated module names unique across runs)
    * `:files` - like `:file`, but names each source by index (for
      multi-feature runs asserting on per-feature uris)
    * `:messages` - a path enabling the Cucumber Messages sink for this run
      (mirroring `config :cucumber, messages: path`); the NDJSON file is
      flushed when the nested run finishes
    * `:seed` - seed for the nested run (`0` runs scenarios in definition
      order — required when asserting on cross-scenario ordering, e.g.
      comparing message streams); defaults to the outer suite's seed

  Returns a map with:

    * `:total`, `:failures`, `:skipped`, `:excluded` - from `ExUnit.run/1`
    * `:passed` - convenience: total minus failures/skipped/excluded
    * `:output` - everything the nested run printed (assert error messages
      here; ANSI colors are disabled in the nested run, so the output is
      plain text even when the outer run is on a TTY)
    * `:events` - events recorded via `Collector.record/1`, in order
    * `:attachments` - `Cucumber.Attachment` structs recorded during the run
    * `:messages` - the decoded message envelopes (only with `:messages`)
    * `:module` - the generated test module
  """
  def run_feature(source, opts \\ []) do
    run_features([source], opts)
  end

  @doc """
  Like `run_feature/2`, but compiles several feature sources into separate
  modules and executes them in one nested run — for behaviors that span
  feature modules (e.g. run-level hooks).

  The `:file` option, when given, names the first source; the rest get
  unique generated paths. The result's `:module` is the first generated
  module; `:modules` carries all of them.
  """
  def run_features(sources, opts \\ []) when is_list(sources) do
    step_modules = opts |> Keyword.get(:steps, []) |> List.wrap()
    hook_modules = opts |> Keyword.get(:hooks, []) |> List.wrap()
    parameter_types = opts |> Keyword.get(:parameter_types, []) |> List.wrap() |> merge_types()

    registry = build_registry(step_modules, parameter_types)

    # Each run_feature call is its own isolated cucumber run: reset the
    # coordinator so run-level state (before_all/after_all) from a previous
    # behavior test can't leak in.
    Cucumber.RunCoordinator.ensure_started()
    Collector.reset()

    named_files = Keyword.get(opts, :files) || List.wrap(Keyword.get(opts, :file))

    features =
      sources
      |> Enum.with_index()
      |> Enum.map(fn {source, index} ->
        file = Enum.at(named_files, index) || unique_feature_path()

        source
        |> Gherkin.Parser.parse(file)
        |> Map.put(:file, file)
        |> Map.put(:source, source)
      end)

    # The same shared compilation path compile_features!/1 uses: run-unique
    # pickle ids threaded across features, message sink configured when a
    # path is given
    modules =
      Cucumber.Compiler.compile_all!(
        features,
        registry,
        hook_modules,
        parameter_types,
        opts[:messages]
      )

    {result, output} = run_isolated(modules, Keyword.take(opts, [:seed]))

    %{
      total: result.total,
      failures: result.failures,
      skipped: result.skipped,
      excluded: result.excluded,
      passed: result.total - result.failures - result.skipped - result.excluded,
      output: output,
      events: Collector.events(),
      attachments: Cucumber.RunCoordinator.attachments(),
      messages: read_messages(opts[:messages]),
      module: List.first(modules),
      modules: modules
    }
  end

  # The nested run's after_suite callback flushes the NDJSON file before
  # ExUnit.run/1 returns, so it is readable here.
  defp read_messages(nil), do: nil

  defp read_messages(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  @doc """
  Runs already-compiled test modules in a nested ExUnit run with neutral
  include/exclude filters, so outer-suite filters (e.g. `mix test --exclude
  cucumber`, which would exclude every generated module via its `:cucumber`
  moduletag) cannot distort the nested result. Safe to swap globally: see
  the moduledoc.

  Accepts a `:seed` option for the nested run (see `run_feature/2`).

  Returns `{result, output}`. Prefer `run_feature/2`; this is for tests
  that drive `Cucumber.Compiler.compile_features!/1` themselves.
  """
  def run_isolated(modules, opts \\ []) do
    config = ExUnit.configuration()

    try do
      # Colors off so captured output is plain text regardless of whether
      # the outer run is on a TTY — assertions parse this output
      ExUnit.configure(include: [], exclude: [], colors: [enabled: false])

      case Keyword.fetch(opts, :seed) do
        {:ok, seed} -> ExUnit.configure(seed: seed)
        :error -> :ok
      end

      output =
        capture_io(fn ->
          Process.put(__MODULE__, ExUnit.run(modules))
        end)

      {Process.delete(__MODULE__), output}
    after
      ExUnit.configure(
        include: config[:include],
        exclude: config[:exclude],
        seed: config[:seed],
        colors: config[:colors]
      )
    end
  end

  defp build_registry(step_modules, parameter_types) do
    for module <- step_modules,
        {pattern, metadata} <- module.__cucumber_steps__(),
        Cucumber.Discovery.compilable_pattern?(pattern, metadata, parameter_types),
        into: %{} do
      {Cucumber.Discovery.registry_key(pattern), {module, metadata}}
    end
  end

  defp merge_types(parameter_type_modules) do
    for module <- parameter_type_modules,
        {name, definition} <- module.__cucumber_parameter_types__(),
        into: %{} do
      {name, definition}
    end
  end

  defp unique_feature_path do
    "test/fixtures/generated/behavior_#{System.unique_integer([:positive])}.feature"
  end

  @doc """
  Reads a vendored CCK sample's feature source from `test/fixtures/cck/`.

  Defaults to the sample's eponymous feature file
  (`<sample>/<sample>.feature`); pass `file` for samples with several.
  """
  def fixture(sample, file \\ nil) do
    file = file || "#{sample}.feature"
    File.read!(Path.join(["test/fixtures/cck", sample, file]))
  end

  @doc """
  Counts occurrences of `event` in a run's collected `:events`.
  """
  def count(events, event), do: Enum.count(events, &(&1 == event))
end
