defmodule Cucumber do
  @moduledoc """
  Macro for Gherkin-based testing in Elixir.
  Usage:
    use Cucumber, feature: "user_joins_event.feature"
    use Cucumber, feature: "user_joins_event.feature", tags: ["smoke", "auth"]
  """

  defmacro __using__(opts) do
    feature_file = Keyword.fetch!(opts, :feature)
    filter_tags = Keyword.get(opts, :tags, [])
    feature_path = Path.join(["test", "features", feature_file])
    feature = Gherkin.Parser.parse(File.read!(feature_path))

    # Filter scenarios based on tags if filter_tags is provided
    filtered_scenarios =
      if filter_tags == [] do
        feature.scenarios
      else
        # Keep scenarios that have at least one matching tag
        Enum.filter(feature.scenarios, fn scenario ->
          Enum.any?(scenario.tags, &(&1 in filter_tags)) ||
            Enum.any?(feature.tags, &(&1 in filter_tags))
        end)
      end

    # Generate setup block
    setup_block =
      if feature.background do
        quote do
          setup context do
            # Add feature file path to context
            context = Map.put(context, :feature_file, unquote(feature_path))
            # Add feature name to context
            context = Map.put(context, :feature_name, unquote(feature.name))
            # Initialize step history
            context = Map.put(context, :step_history, [])

            Enum.reduce(unquote(Macro.escape(feature.background.steps)), context, fn step, ctx ->
              Cucumber.apply_step(__MODULE__, ctx, step)
            end)
          end
        end
      else
        quote do
          setup context do
            # Add feature file path to context even without background
            context = Map.put(context, :feature_file, unquote(feature_path))
            # Add feature name to context
            context = Map.put(context, :feature_name, unquote(feature.name))
            # Initialize step history
            context = Map.put(context, :step_history, [])
            context
          end
        end
      end

    # Generate test blocks for each filtered scenario
    test_blocks =
      for scenario <- filtered_scenarios do
        quote do
          test unquote(scenario.name), context do
            # Add scenario name to context
            context = Map.put(context, :scenario_name, unquote(scenario.name))

            Enum.reduce(unquote(Macro.escape(scenario.steps)), context, fn step, ctx ->
              Cucumber.apply_step(__MODULE__, ctx, step)
            end)
          end
        end
      end

    quote do
      use ExUnit.Case, async: true

      # Import only the defstep macros that we actually define
      import Cucumber, only: [defstep: 2, defstep: 3]

      # Register module attribute for cucumber patterns
      Module.register_attribute(__MODULE__, :cucumber_patterns, accumulate: true)
      @before_compile Cucumber

      describe unquote(feature.name) do
        unquote(setup_block)
        unquote_splicing(test_blocks)
      end
    end
  end

  # Helper function to call step/2 in the test module with merged args and context
  def apply_step(
        module,
        context,
        %Gherkin.Step{text: text, docstring: docstring, datatable: datatable} = step
      ) do
    # Extract parameters using the Expression module
    patterns = module.__cucumber_patterns__()

    # Find a matching pattern and extract args
    result =
      Enum.find_value(patterns, fn pattern_info ->
        {pattern_text, _} = pattern_info
        compiled_pattern = Cucumber.Expression.compile(pattern_text)

        case Cucumber.Expression.match(text, compiled_pattern) do
          {:match, args} -> {pattern_text, args}
          :no_match -> nil
        end
      end)

    # Get feature file and scenario name from context for error reporting
    feature_file = Map.get(context, :feature_file, "unknown_feature.feature")
    scenario_name = Map.get(context, :scenario_name, "Unknown Scenario")

    # Update step history with this step (pending)
    step_history = Map.get(context, :step_history, [])
    updated_context = Map.put(context, :step_history, step_history ++ [{"pending", step}])

    case result do
      {pattern, args} ->
        try do
          # Merge args into context and add docstring and datatable when present
          context_with_args = Map.put(updated_context, :args, args)

          # Add docstring if present
          context_with_docstring =
            if docstring,
              do: Map.put(context_with_args, :docstring, docstring),
              else: context_with_args

          # Add datatable if present
          context_with_extras =
            if datatable do
              # If first row looks like headers, convert to a list of maps
              if length(datatable) > 1 do
                [headers | rows] = datatable

                # Convert rows to maps using headers as keys
                table_maps =
                  Enum.map(rows, fn row ->
                    Enum.zip(headers, row) |> Enum.into(%{})
                  end)

                Map.put(context_with_docstring, :datatable, %{
                  headers: headers,
                  rows: rows,
                  maps: table_maps,
                  raw: datatable
                })
              else
                # Single row or empty table
                Map.put(context_with_docstring, :datatable, %{
                  headers: [],
                  rows: datatable,
                  maps: [],
                  raw: datatable
                })
              end
            else
              context_with_docstring
            end

          # Call the step function with the enhanced context
          step_result = apply(module, :step, [context_with_extras, pattern])

          # Update step history to mark this step as passed
          current_history = Map.get(context_with_extras, :step_history, [])

          # Enhanced return value handling
          case step_result do
            # When step returns {:ok, map}, merge map into context
            {:ok, value} when is_map(value) ->
              new_context = Map.merge(context, value)
              # Update step history in the new context
              Map.put(
                new_context,
                :step_history,
                List.delete_at(current_history, -1) ++ [{"passed", step}]
              )

            # When step returns a map directly, use it as the new context
            %{} = new_context ->
              # Make sure the step_history is preserved and updated
              history = Map.get(new_context, :step_history, current_history)

              Map.put(
                new_context,
                :step_history,
                List.delete_at(history, -1) ++ [{"passed", step}]
              )

            # When step returns :ok or nil, keep existing context
            result when result == :ok or result == nil ->
              # Update step history in the existing context
              Map.put(
                context,
                :step_history,
                List.delete_at(current_history, -1) ++ [{"passed", step}]
              )

            # When step returns {:error, reason}, raise a StepError
            {:error, reason} ->
              # Update step history to mark this step as failed
              failed_history = List.delete_at(current_history, -1) ++ [{"failed", step}]

              raise Cucumber.StepError.failed_step(
                      step,
                      pattern,
                      reason,
                      feature_file,
                      scenario_name,
                      failed_history
                    )

            # For any other return value, just keep the current context
            _other ->
              # Update step history in the existing context
              Map.put(
                context,
                :step_history,
                List.delete_at(current_history, -1) ++ [{"passed", step}]
              )
          end
        rescue
          error ->
            # If any other error occurs during step execution, wrap it in a StepError
            current_history = Map.get(updated_context, :step_history, [])
            failed_history = List.delete_at(current_history, -1) ++ [{"failed", step}]

            reraise Cucumber.StepError.failed_step(
                      step,
                      pattern,
                      error,
                      feature_file,
                      scenario_name,
                      failed_history
                    ),
                    __STACKTRACE__
        end

      nil ->
        # No matching pattern found, raise a helpful error with suggestions
        raise Cucumber.StepError.missing_step_definition(
                step,
                feature_file,
                scenario_name,
                step_history
              )
    end
  end

  # New simpler API: defstep "pattern", context do ... end
  defmacro defstep(pattern, context \\ nil, do: block) do
    quote do
      # Register the pattern in a module attribute for lookup
      @cucumber_patterns {unquote(pattern), unquote(Macro.escape(block))}

      # Generate a step/2 function with pattern as second parameter and merged context+args
      def step(context_value, unquote(pattern)) do
        # Bind context to the actual value (already contains args)
        unquote(context || quote(do: context)) = context_value
        unquote(block)
      end
    end
  end

  # __before_compile__ generates the function to return cucumber patterns
  defmacro __before_compile__(env) do
    patterns = Module.get_attribute(env.module, :cucumber_patterns) || []

    quote do
      # Helper function to get defined patterns for lookup
      def __cucumber_patterns__ do
        unquote(Macro.escape(patterns))
      end

      # Fallback step function for unmatched patterns
      def step(_context, _pattern) do
        raise "No matching step definition found"
      end
    end
  end
end
