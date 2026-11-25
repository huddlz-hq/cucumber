defmodule Cucumber.Behavior.CaseTemplateTest do
  @moduledoc """
  Behavior tests for `config :cucumber, case_template: module`: generated
  feature modules `use` the template instead of `ExUnit.Case`, so its
  `setup` callbacks (and their context) and its `test` macro apply to every
  scenario. Step definition modules import their own.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule FeatureCase do
    use ExUnit.CaseTemplate

    using opts do
      quote do
        import ExUnit.Case, except: [test: 3]
        import Cucumber.Behavior.CaseTemplateTest.FeatureCase, only: [test: 3]

        @template_async unquote(opts[:async])
        def template_async, do: @template_async
      end
    end

    setup do
      Collector.record(:template_setup)
      %{from_template: :template_value}
    end

    defmacro test(name, context, do: block) do
      quote do
        ExUnit.Case.test unquote(name), unquote(context) do
          Collector.record(:template_test_start)
          result = unquote(block)
          Collector.record(:template_test_end)
          result
        end
      end
    end
  end

  defmodule Steps do
    use Cucumber.StepDefinition

    step "a step reads the template's setup", context do
      Collector.record({:step, Map.get(context, :from_template)})
      :ok
    end

    step "a step that passes the second time", _context do
      Collector.record(:second_time)

      if Enum.count(Collector.events(), &(&1 == :second_time)) < 2 do
        raise "fails the first attempt"
      end

      :ok
    end
  end

  defmodule Hooks do
    use Cucumber.Hooks

    before_scenario _context do
      Collector.record(:before_scenario)
      :ok
    end
  end

  @feature """
  Feature: case template
    Scenario: uses the template
      Given a step reads the template's setup
  """

  # Unloads the generated test modules once the test is done
  defp purge_on_exit(modules) do
    on_exit(fn ->
      for module <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)
  end

  defp run(source, opts) do
    run = run_feature(source, opts)
    purge_on_exit(run.modules)
    run
  end

  # Compiles a no-step feature through compile_features!/1 with the given
  # app env case template and opts, and runs it
  defp compile_and_run(env_template, opts) do
    # Relative, so the generated module name stays a valid alias
    dir = "tmp/case_template_#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    feature = Path.join(dir, "template.feature")
    File.write!(feature, "Feature: case template\n  Scenario: no steps\n")

    previous = Application.fetch_env(:cucumber, :case_template)
    Application.put_env(:cucumber, :case_template, env_template)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:cucumber, :case_template, value)
        :error -> Application.delete_env(:cucumber, :case_template)
      end
    end)

    modules =
      Cucumber.compile_features!([features: feature, steps: [], support: []] ++ opts)

    purge_on_exit(modules)
    {result, _output} = Cucumber.BehaviorCase.run_isolated(modules)
    assert result.failures == 0 and result.total == 1
    modules
  end

  test "generated modules use the configured case template" do
    run = run(@feature, steps: [Steps], hooks: [Hooks], case_template: FeatureCase)

    assert run.passed == 1

    assert run.events == [
             :template_setup,
             :template_test_start,
             :before_scenario,
             {:step, :template_value},
             :template_test_end
           ]
  end

  test "with retries, the template's setup and test wrapper run once around all attempts" do
    run =
      run(
        """
        Feature: case template retries
          @retry-1
          Scenario: flaky
            Given a step that passes the second time
        """,
        steps: [Steps],
        hooks: [Hooks],
        case_template: FeatureCase
      )

    assert run.passed == 1

    assert run.events == [
             :template_setup,
             :template_test_start,
             :before_scenario,
             :second_time,
             :before_scenario,
             :second_time,
             :template_test_end
           ]
  end

  test "the template receives the feature's async flag" do
    sync = run(@feature, steps: [Steps], case_template: FeatureCase)
    async = run("@async\n" <> @feature, steps: [Steps], case_template: FeatureCase)

    assert sync.module.template_async() == false
    assert async.module.template_async() == true
  end

  test "without a case template, generated modules use ExUnit.Case" do
    run = run(@feature, steps: [Steps], hooks: [Hooks])

    assert run.passed == 1
    assert run.events == [:before_scenario, {:step, nil}]
    refute function_exported?(run.module, :template_async, 0)
  end

  test "compile_features!/1 reads the case template from the application env" do
    compile_and_run(FeatureCase, [])

    assert Collector.events() == [:template_setup, :template_test_start, :template_test_end]
  end

  test "an explicit case_template: nil overrides the application env" do
    [module] = compile_and_run(FeatureCase, case_template: nil)

    assert Collector.events() == []
    refute function_exported?(module, :template_async, 0)
  end
end
