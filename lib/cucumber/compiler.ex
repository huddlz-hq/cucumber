defmodule Cucumber.Compiler do
  @moduledoc """
  Compiles discovered features and steps into ExUnit test modules.

  The compilation pipeline works as follows:

  1. Discovery finds all feature files and step definitions via `Cucumber.Discovery`
  2. For each feature file, a unique ExUnit test module is generated
  3. Module names are derived from the feature file path
     (e.g., `test/features/auth.feature` becomes `Test.Features.AuthTest`)
  4. Background steps become ExUnit `setup` blocks
  5. Each scenario becomes an ExUnit `test` block
  6. Scenario Outlines are expanded into individual scenarios using Examples data
  7. Tags from features and scenarios are mapped to ExUnit tags for filtering
  8. Hooks are wired into setup/teardown via `Cucumber.Hooks`
  """

  alias Cucumber.Discovery
  alias Gherkin.{Examples, Scenario, ScenarioOutline, Step}

  @doc """
  Compiles all discovered features into ExUnit test modules.
  """
  @spec compile_features!(keyword()) :: [module()]
  def compile_features!(opts \\ []) do
    # Discover features and steps
    %Discovery.DiscoveryResult{
      features: features,
      step_registry: step_registry,
      hook_modules: hook_modules,
      parameter_types: parameter_types
    } = Discovery.discover(opts)

    # Start (or reset) the run-wide coordinator before any test executes
    Cucumber.RunCoordinator.ensure_started()

    # Generate a test module for each feature
    for feature <- features do
      compile_feature!(feature, step_registry, hook_modules, parameter_types: parameter_types)
    end
  end

  @doc false
  # Public so test harnesses (e.g. Cucumber.BehaviorCase) can compile a single
  # parsed feature against an explicit step registry, bypassing discovery.
  # The feature must carry a `:file` key (as set by Cucumber.Discovery).
  @spec compile_feature!(map(), map(), [module()], keyword()) :: module()
  def compile_feature!(feature, step_registry, hook_modules, opts \\ []) do
    warn_on_empty_feature(feature)

    parameter_types = Keyword.get(opts, :parameter_types, %{})

    # Generate module name from feature file path
    module_name = generate_module_name(feature.file)

    # Check if feature has @async tag
    async = "async" in feature.tags

    # Collect all hooks
    all_hooks = Cucumber.Hooks.collect_hooks(hook_modules)

    # The registry and hook list live in :persistent_term rather than being
    # Macro.escape'd into every generated module (which bloats each module's
    # AST with a full copy). Keys are unique per compilation, so repeated
    # compiles (mix test.watch, test harnesses) can't see stale data.
    runtime_key = {Cucumber, :runtime_data, :erlang.unique_integer([:positive])}

    :persistent_term.put(runtime_key, %{
      step_registry: step_registry,
      hooks: all_hooks,
      parameter_types: parameter_types
    })

    # Generate test module AST
    ast =
      quote do
        defmodule unquote(module_name) do
          use ExUnit.Case, async: unquote(async)

          # Tag with cucumber and feature name
          @moduletag :cucumber
          @moduletag unquote(feature_tag(feature.name))

          # Add feature tags as module tags (except reserved ones)
          unquote_splicing(
            for tag <- feature.tags, tag != "async" do
              quote do: @moduletag(unquote(String.to_atom(tag)))
            end
          )

          # Runtime data accessors (registry and hooks live in :persistent_term)
          def __step_registry__ do
            :persistent_term.get(unquote(Macro.escape(runtime_key))).step_registry
          end

          @doc false
          def __cucumber_feature_hooks__ do
            :persistent_term.get(unquote(Macro.escape(runtime_key))).hooks
          end

          @doc false
          def __cucumber_parameter_types__ do
            :persistent_term.get(unquote(Macro.escape(runtime_key))).parameter_types
          end

          @doc false
          def __cucumber_runtime__ do
            :persistent_term.get(unquote(Macro.escape(runtime_key)))
          end

          # Expand scenario outlines and rules, generate test for each scenario
          unquote_splicing(
            for scenario <- expand_feature(feature) do
              generate_scenario_test(scenario, feature, async)
            end
          )
        end
      end

    # Compile the module
    [{^module_name, _}] = Code.compile_quoted(ast, feature.file)
    module_name
  end

  @doc false
  # Public for testing. Emits a compile-time warning when a feature parses with
  # zero scenarios — usually a sign the parser silently dropped them. The
  # synthetic stacktrace makes editors highlight the warning on the feature
  # file itself rather than inside the cucumber library.
  def warn_on_empty_feature(%{scenarios: []} = feature) do
    if Map.get(feature, :rules, []) == [] do
      stacktrace = [
        {__MODULE__, :compile_feature, 3, [file: String.to_charlist(feature.file), line: 1]}
      ]

      IO.warn(
        "Cucumber: feature file #{feature.file} parsed with zero scenarios — " <>
          "scenarios may have been silently dropped by the parser.",
        stacktrace
      )
    else
      :ok
    end
  end

  def warn_on_empty_feature(_feature), do: :ok

  defp generate_module_name(file_path) do
    # Convert path like "test/features/authentication.feature"
    # to Test.Features.AuthenticationTest
    file_path
    |> Path.rootname()
    |> Path.split()
    |> Enum.map_join(".", &Macro.camelize/1)
    |> Kernel.<>("Test")
    |> String.to_atom()
  end

  defp feature_tag(name) do
    # Convert "User Authentication" to :feature_user_authentication
    tag_name =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    :"feature_#{tag_name}"
  end

  defp generate_scenario_test(scenario, feature, async) do
    # Generate tags for the scenario
    tags =
      scenario.tags
      |> Enum.map(&String.to_atom/1)
      |> Enum.map(fn tag -> quote do: @tag(unquote(tag)) end)

    background_steps = if feature.background, do: feature.background.steps, else: []

    # The whole scenario lifecycle (before hooks, background, steps, after
    # hooks) runs inside the test body via the runtime — see
    # Cucumber.Runtime.run_scenario/3.
    scenario_spec = %{
      feature_file: feature.file,
      feature_tags: feature.tags,
      async: async,
      scenario_name: scenario.name,
      scenario_line: (scenario.line || 0) + 1,
      background_steps: background_steps,
      steps: scenario.steps
    }

    quote do
      unquote_splicing(tags)
      @tag unquote(scenario_tag(scenario.name))
      @tag scenario_line: unquote((scenario.line || 0) + 1)

      test unquote(scenario.name), exunit_context do
        Cucumber.Runtime.run_scenario(
          exunit_context,
          unquote(Macro.escape(scenario_spec)),
          __cucumber_runtime__()
        )
      end
    end
  end

  defp scenario_tag(name) do
    # Convert "User logs in successfully" to :scenario_user_logs_in_successfully
    tag_name =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    :"scenario_#{tag_name}"
  end

  # Scenario Outline and Rule expansion functions

  @doc false
  # Public for testing - expands a feature's scenarios and rules into the
  # flat list of concrete scenarios that become tests.
  @spec expand_feature(map()) :: [Gherkin.Scenario.t()]
  def expand_feature(feature) do
    rules = Map.get(feature, :rules, [])
    expand_all_scenarios(feature.scenarios) ++ Enum.flat_map(rules, &expand_rule/1)
  end

  # Scenarios inside a rule get the rule background's steps prepended (the
  # feature background stays in the module's setup block, preserving the
  # spec order: feature background, rule background, scenario steps), the
  # rule's tags merged in, and the rule name prefixed so identically-named
  # scenarios in different rules don't collide as ExUnit test names.
  defp expand_rule(%Gherkin.Rule{} = rule) do
    rule_background_steps = if rule.background, do: rule.background.steps, else: []

    rule.scenarios
    |> expand_all_scenarios()
    |> Enum.map(fn %Scenario{} = scenario ->
      %Scenario{
        scenario
        | name: prefix_with_rule(rule.name, scenario.name),
          steps: rule_background_steps ++ scenario.steps,
          tags: Enum.uniq(rule.tags ++ scenario.tags),
          rule: rule.name
      }
    end)
  end

  defp prefix_with_rule("", scenario_name), do: scenario_name
  defp prefix_with_rule(rule_name, scenario_name), do: "#{rule_name}: #{scenario_name}"

  @doc false
  # Public for testing - expands scenario outlines into concrete scenarios
  @spec expand_all_scenarios([Gherkin.Scenario.t() | Gherkin.ScenarioOutline.t()]) :: [
          Gherkin.Scenario.t()
        ]
  def expand_all_scenarios(scenarios) do
    Enum.flat_map(scenarios, fn
      %Scenario{} = scenario -> [scenario]
      %ScenarioOutline{} = outline -> expand_outline(outline)
    end)
  end

  defp expand_outline(%ScenarioOutline{examples: []} = outline) do
    raise """
    Scenario Outline '#{outline.name}' has no Examples section.

    Every Scenario Outline must have at least one Examples block with data rows.
    """
  end

  defp expand_outline(%ScenarioOutline{} = outline) do
    outline.examples
    |> Enum.flat_map(fn %Examples{} = examples ->
      examples.table_body
      |> Enum.with_index(1)
      |> Enum.map(fn {row, row_num} ->
        substitutions = Enum.zip(examples.table_header, row) |> Map.new()

        %Scenario{
          name: generate_test_name(outline.name, examples.name, row_num),
          steps: substitute_steps(outline.steps, substitutions),
          tags: Enum.uniq(outline.tags ++ examples.tags),
          line: outline.line
        }
      end)
    end)
  end

  defp generate_test_name(outline_name, "", row_num) do
    "#{outline_name} (row #{row_num})"
  end

  defp generate_test_name(outline_name, examples_name, row_num) do
    "#{outline_name} (#{examples_name}: row #{row_num})"
  end

  defp substitute_steps(steps, substitutions) do
    Enum.map(steps, fn %Step{} = step ->
      %{
        step
        | text: substitute_placeholders(step.text, substitutions),
          docstring: substitute_placeholders(step.docstring, substitutions),
          datatable: substitute_datatable(step.datatable, substitutions)
      }
    end)
  end

  defp substitute_placeholders(nil, _substitutions), do: nil

  defp substitute_placeholders(text, substitutions) do
    Enum.reduce(substitutions, text, fn {key, value}, acc ->
      String.replace(acc, "<#{key}>", value)
    end)
  end

  defp substitute_datatable(nil, _substitutions), do: nil

  defp substitute_datatable(table, substitutions) do
    Enum.map(table, fn row ->
      Enum.map(row, &substitute_placeholders(&1, substitutions))
    end)
  end
end
