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
      import Cucumber.BehaviorCase, only: [run_feature: 1, run_feature: 2]
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

  @doc """
  Compiles and runs a Gherkin feature source against the given step modules.

  ## Options

    * `:steps` - list of modules defined with `use Cucumber.StepDefinition`
    * `:hooks` - list of modules defined with `use Cucumber.Hooks`
    * `:file` - synthetic feature path (defaults to a unique generated path,
      which also keeps generated module names unique across runs)

  Returns a map with:

    * `:total`, `:failures`, `:skipped`, `:excluded` - from `ExUnit.run/1`
    * `:passed` - convenience: total minus failures/skipped/excluded
    * `:output` - everything the nested run printed (assert error messages here)
    * `:events` - events recorded via `Collector.record/1`, in order
    * `:module` - the generated test module
  """
  def run_feature(source, opts \\ []) do
    step_modules = opts |> Keyword.get(:steps, []) |> List.wrap()
    hook_modules = opts |> Keyword.get(:hooks, []) |> List.wrap()
    file = Keyword.get_lazy(opts, :file, &unique_feature_path/0)

    feature =
      source
      |> Gherkin.Parser.parse()
      |> Map.put(:file, file)

    registry = build_registry(step_modules)

    Collector.reset()

    module = Cucumber.Compiler.compile_feature!(feature, registry, hook_modules)
    {result, output} = run_isolated(module)

    %{
      total: result.total,
      failures: result.failures,
      skipped: result.skipped,
      excluded: result.excluded,
      passed: result.total - result.failures - result.skipped - result.excluded,
      output: output,
      events: Collector.events(),
      module: module
    }
  end

  # Runs the module in a nested ExUnit run with neutral include/exclude
  # filters, so outer-suite filters (e.g. `mix test --exclude cucumber`,
  # which would exclude every generated module via its :cucumber moduletag)
  # cannot distort the nested result. Safe to swap globally: see moduledoc.
  defp run_isolated(module) do
    config = ExUnit.configuration()

    try do
      ExUnit.configure(include: [], exclude: [])

      output =
        capture_io(fn ->
          Process.put(__MODULE__, ExUnit.run([module]))
        end)

      {Process.delete(__MODULE__), output}
    after
      ExUnit.configure(include: config[:include], exclude: config[:exclude])
    end
  end

  defp build_registry(step_modules) do
    for module <- step_modules,
        {pattern, metadata} <- module.__cucumber_steps__(),
        into: %{} do
      {pattern, {module, metadata}}
    end
  end

  defp unique_feature_path do
    "test/fixtures/generated/behavior_#{System.unique_integer([:positive])}.feature"
  end
end
