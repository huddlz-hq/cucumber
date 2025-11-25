defmodule Cucumber.Compiler do
  @moduledoc """
  Compiles discovered features and steps into ExUnit test modules.
  """

  alias Cucumber.Discovery

  @doc """
  Compiles all discovered features into ExUnit test modules.
  """
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

          # Generate test for each scenario
          unquote_splicing(
            for scenario <- feature.scenarios do
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
    # Even without background, we may need setup for feature-level hooks
    if feature.tags != [] do
      build_setup_block([], feature, all_hooks)
    else
      nil
    end
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
        # Initialize cucumber context
        context =
          Map.merge(context, %{
            step_history: [],
            feature_file: unquote(feature.file),
            feature_tags: unquote(feature.tags),
            async: unquote(async)
          })

        # Run feature-level before hooks
        result =
          Cucumber.Hooks.run_before_hooks(
            unquote(Macro.escape(all_hooks)),
            context,
            unquote(feature.tags)
          )

        case result do
          {:ok, context} ->
            # Execute background steps if any
            unquote_splicing(background_steps)

            # Register cleanup for feature-level after hooks
            on_exit(fn ->
              Cucumber.Hooks.run_after_hooks(
                unquote(Macro.escape(all_hooks)),
                context,
                unquote(feature.tags)
              )
            end)

            {:ok, context}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp generate_scenario_test(scenario, step_registry, all_hooks, feature, async) do
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
        # Initialize cucumber context
        context =
          Map.merge(context, %{
            scenario_name: unquote(scenario.name),
            feature_file: unquote(feature.file),
            scenario_line: unquote((scenario.line || 0) + 1),
            async: unquote(async),
            step_history: []
          })

        # Run scenario-specific before hooks (excluding feature-level hooks)
        {:ok, context} =
          Cucumber.Hooks.run_scenario_before_hooks(
            unquote(Macro.escape(all_hooks)),
            context,
            unquote(scenario.tags),
            unquote(feature.tags)
          )

        # Execute scenario steps
        unquote_splicing(
          for step <- scenario.steps do
            generate_step_execution(step, step_registry)
          end
        )

        # Run scenario-specific after hooks (excluding feature-level hooks)
        Cucumber.Hooks.run_scenario_after_hooks(
          unquote(Macro.escape(all_hooks)),
          context,
          unquote(scenario.tags),
          unquote(feature.tags)
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
end
