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
      step_registry: step_registry
    } = Discovery.discover(opts)

    # Generate a test module for each feature
    for feature <- features do
      compile_feature(feature, step_registry)
    end
  end

  defp compile_feature(feature, step_registry) do
    # Generate module name from feature file path
    module_name = generate_module_name(feature.file)

    # Check if feature has @async tag
    async = "async" in feature.tags

    # Generate test module AST
    ast =
      quote do
        defmodule unquote(module_name) do
          use ExUnit.Case, async: unquote(async)

          # Tag with cucumber and feature name
          @moduletag :cucumber
          @moduletag unquote(feature_tag(feature.name))

          # Store the step registry for runtime access
          def __step_registry__ do
            unquote(Macro.escape(Map.new(step_registry)))
          end

          # If there's a background, create setup block
          unquote(generate_setup(feature.background, step_registry))

          # Generate test for each scenario
          unquote_splicing(
            for scenario <- feature.scenarios do
              generate_scenario_test(scenario, step_registry)
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

  defp generate_setup(nil, _step_registry), do: nil

  defp generate_setup(background, step_registry) do
    quote do
      setup context do
        # Initialize cucumber context
        context =
          Map.merge(context, %{
            step_history: []
          })

        # Execute background steps
        unquote_splicing(
          for step <- background.steps do
            generate_step_execution(step, step_registry)
          end
        )

        {:ok, context}
      end
    end
  end

  defp generate_scenario_test(scenario, step_registry) do
    # Generate tags for the scenario
    tags =
      scenario.tags
      |> Enum.map(&String.to_atom/1)
      |> Enum.map(fn tag -> quote do: @tag(unquote(tag)) end)

    quote do
      unquote_splicing(tags)
      @tag unquote(scenario_tag(scenario.name))

      test unquote(scenario.name), context do
        # Add scenario info to context
        context = Map.put(context, :scenario_name, unquote(scenario.name))

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
end
