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
      hook_modules: hook_modules
    } = Discovery.discover(opts)

    # Generate a test module for each feature
    for feature <- features do
      compile_feature(feature, step_registry, hook_modules)
    end
  end

  defp compile_feature(feature, step_registry, hook_modules) do
    # Generate module name from feature file path
    module_name = generate_module_name(feature.file)

    # Check if feature has @async tag
    async = "async" in feature.tags

    # Collect all hooks
    all_hooks = Cucumber.Hooks.collect_hooks(hook_modules)

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

          # Store the step registry for runtime access
          def __step_registry__ do
            unquote(Macro.escape(Map.new(step_registry)))
          end

          # If there's a background or feature-level tags, create setup block
          unquote(generate_setup(feature.background, step_registry, feature, all_hooks))

          # Expand scenario outlines and generate test for each scenario
          unquote_splicing(
            for scenario <- expand_all_scenarios(feature.scenarios) do
              generate_scenario_test(scenario, step_registry, all_hooks, feature, async)
            end
          )
        end
      end

    # Compile the module
    [{^module_name, _}] = Code.compile_quoted(ast, feature.file)
    module_name
  end

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

  defp generate_setup(nil, _step_registry, feature, all_hooks) do
    # Always generate setup to run hooks for all scenarios
    build_setup_block([], feature, all_hooks)
  end

  defp generate_setup(background, step_registry, feature, all_hooks) do
    background_steps =
      for step <- background.steps do
        generate_step_execution(step, step_registry)
      end

    build_setup_block(background_steps, feature, all_hooks)
  end

  # Shared helper to build the setup block with hooks and optional background steps
  defp build_setup_block(background_steps, feature, all_hooks) do
    async = "async" in feature.tags

    quote do
      setup context do
        # ExUnit puts @tag values directly in context as keys
        # Filter out standard ExUnit keys to get scenario tags
        exunit_keys = [
          :async,
          :line,
          :module,
          :registered,
          :file,
          :test,
          :describe,
          :describe_line,
          :test_type,
          :test_pid,
          :test_group
        ]

        scenario_tags =
          context
          |> Map.keys()
          |> Enum.filter(&is_atom/1)
          |> Enum.reject(&(&1 in exunit_keys))
          |> Enum.map(&to_string/1)

        # Combine feature tags + scenario tags for hook matching
        all_tags = Enum.uniq(unquote(feature.tags) ++ scenario_tags)

        # Initialize cucumber context
        context =
          Map.merge(context, %{
            step_history: [],
            feature_file: unquote(feature.file),
            feature_tags: unquote(feature.tags),
            scenario_tags: scenario_tags,
            async: unquote(async)
          })

        # Run ALL matching hooks (global + feature + scenario tags)
        result =
          Cucumber.Hooks.run_before_hooks(
            unquote(Macro.escape(all_hooks)),
            context,
            all_tags
          )

        case result do
          {:ok, context} ->
            # Execute background steps if any
            unquote_splicing(background_steps)

            # Register cleanup for after hooks
            on_exit(fn ->
              Cucumber.Hooks.run_after_hooks(
                unquote(Macro.escape(all_hooks)),
                context,
                all_tags
              )
            end)

            {:ok, context}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp generate_scenario_test(scenario, step_registry, _all_hooks, feature, _async) do
    # Generate tags for the scenario
    tags =
      scenario.tags
      |> Enum.map(&String.to_atom/1)
      |> Enum.map(fn tag -> quote do: @tag(unquote(tag)) end)

    quote do
      unquote_splicing(tags)
      @tag unquote(scenario_tag(scenario.name))
      @tag scenario_line: unquote((scenario.line || 0) + 1)

      test unquote(scenario.name), context do
        # Add scenario-specific context (hooks already ran in setup)
        context =
          Map.merge(context, %{
            scenario_name: unquote(scenario.name),
            feature_file: unquote(feature.file),
            scenario_line: unquote((scenario.line || 0) + 1)
          })

        # Execute scenario steps
        unquote_splicing(
          for step <- scenario.steps do
            generate_step_execution(step, step_registry)
          end
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

  defp generate_step_execution(step, _step_registry) do
    quote do
      context =
        Cucumber.Runtime.execute_step(
          context,
          unquote(Macro.escape(step)),
          __MODULE__.__step_registry__()
        )
    end
  end

  # Scenario Outline expansion functions

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
