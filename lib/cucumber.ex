defmodule Cucumber do
  @moduledoc """
  A behavior-driven development (BDD) testing framework for Elixir using Gherkin syntax.

  Cucumber is a testing framework that allows you to write executable specifications
  in natural language. It bridges the gap between technical and non-technical stakeholders
  by allowing tests to be written in plain language while being executed as code.

  ## Usage

  To use Cucumber in your test file:

      defmodule UserAuthenticationTest do
        use Cucumber, feature: "user_authentication.feature"
        
        defstep "I am on the sign in page", context do
          # Step implementation
          Map.put(context, :current_page, :sign_in)
        end
        
        # More step definitions
      end

  You can also filter scenarios by tags:

      # Only run scenarios tagged with "smoke" or "auth"
      use Cucumber, feature: "user_authentication.feature", tags: ["smoke", "auth"]

  ## Key Features

  * Gherkin Support - Write tests in familiar Given/When/Then format
  * Parameter Types - Define step patterns with typed parameters like `{string}`, `{int}`
  * Data Tables - Pass structured data to your steps
  * DocStrings - Include multi-line text blocks in your steps
  * Background Steps - Define common setup steps for all scenarios
  * Tag Filtering - Run subsets of scenarios using tags
  * Context Passing - Share state between steps with a simple context map
  * Rich Error Reporting - Clear error messages with step execution history
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
  @doc """
  Applies a step from a feature file to a matching step definition.

  This function is used internally by the Cucumber framework to execute steps.
  It handles the pattern matching, parameter extraction, and context management.

  ## Parameters

  - `module` - The test module containing step definitions
  - `context` - The current context map
  - `step` - The `Gherkin.Step` struct to execute

  ## Returns

  Returns the updated context map if the step succeeds, or raises a `Cucumber.StepError`
  if the step fails or no matching step definition is found.
  """
  def apply_step(
        module,
        context,
        %Gherkin.Step{text: text, docstring: docstring, datatable: datatable} = step
      ) do
    # Get feature file and scenario name from context for error reporting
    feature_file = Map.get(context, :feature_file, "unknown_feature.feature")
    scenario_name = Map.get(context, :scenario_name, "Unknown Scenario")

    # Update step history with this step (pending)
    step_history = Map.get(context, :step_history, [])
    updated_context = Map.put(context, :step_history, step_history ++ [{"pending", step}])

    # Find a matching pattern and extract args
    case find_matching_pattern(module, text) do
      {pattern, args} ->
        step_info = %{
          module: module,
          context: updated_context,
          step: step,
          pattern: pattern,
          args: args,
          docstring: docstring,
          datatable: datatable,
          feature_file: feature_file,
          scenario_name: scenario_name
        }

        execute_step(step_info)

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

  defp execute_step(%{
         module: module,
         context: context,
         step: step,
         pattern: pattern,
         args: args,
         docstring: docstring,
         datatable: datatable,
         feature_file: feature_file,
         scenario_name: scenario_name
       }) do
    # Build context with all extras
    context_with_extras = build_context_with_extras(context, args, docstring, datatable)

    # Call the step function with the enhanced context
    step_result = module.step(context_with_extras, pattern)

    # Handle the result
    handle_step_result(step_result, context, step, pattern, feature_file, scenario_name)
  rescue
    error ->
      # If any other error occurs during step execution, wrap it in a StepError
      current_history = Map.get(context, :step_history, [])
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

  # Private helper functions for apply_step/3

  defp find_matching_pattern(module, text) do
    patterns = module.__cucumber_patterns__()

    Enum.find_value(patterns, fn {pattern_text, _} ->
      compiled_pattern = Cucumber.Expression.compile(pattern_text)

      case Cucumber.Expression.match(text, compiled_pattern) do
        {:match, args} -> {pattern_text, args}
        :no_match -> nil
      end
    end)
  end

  defp build_context_with_extras(context, args, docstring, datatable) do
    context
    |> Map.put(:args, args)
    |> add_docstring(docstring)
    |> add_datatable(datatable)
  end

  defp add_docstring(context, nil), do: context
  defp add_docstring(context, docstring), do: Map.put(context, :docstring, docstring)

  defp add_datatable(context, nil), do: context

  defp add_datatable(context, datatable) do
    datatable_map =
      if length(datatable) > 1 do
        [headers | rows] = datatable

        table_maps =
          Enum.map(rows, fn row ->
            Enum.zip(headers, row) |> Enum.into(%{})
          end)

        %{
          headers: headers,
          rows: rows,
          maps: table_maps,
          raw: datatable
        }
      else
        %{
          headers: [],
          rows: datatable,
          maps: [],
          raw: datatable
        }
      end

    Map.put(context, :datatable, datatable_map)
  end

  defp update_step_history(context, status, step) do
    current_history = Map.get(context, :step_history, [])
    updated_history = List.delete_at(current_history, -1) ++ [{status, step}]
    Map.put(context, :step_history, updated_history)
  end

  defp handle_step_result(step_result, context, step, pattern, feature_file, scenario_name) do
    case step_result do
      {:ok, value} when is_map(value) ->
        Map.merge(context, value)
        |> update_step_history("passed", step)

      %{} = new_context ->
        new_context
        |> update_step_history("passed", step)

      result when result == :ok or result == nil ->
        update_step_history(context, "passed", step)

      {:error, reason} ->
        current_history = Map.get(context, :step_history, [])
        failed_history = List.delete_at(current_history, -1) ++ [{"failed", step}]

        raise Cucumber.StepError.failed_step(
                step,
                pattern,
                reason,
                feature_file,
                scenario_name,
                failed_history
              )

      _other ->
        update_step_history(context, "passed", step)
    end
  end

  @doc """
  Defines a step pattern and its implementation.

  The `defstep/3` macro is used to define step implementations that match steps in feature files.
  It supports pattern parameters like `{string}`, `{int}`, `{float}`, and `{word}`.

  ## Parameters

  - `pattern` - The step pattern to match (e.g., "I click {string} button")
  - `context` - The variable name to bind the context to (optional)
  - `do` - The block of code to execute when the step matches

  ## Return Values

  Step implementations can return values in several ways:

  - `:ok` - For steps that perform actions but don't need to update context
  - A map - To directly replace the context
  - `{:ok, map}` - To merge new values into the context
  - `{:error, reason}` - To indicate a step failure with a reason

  ## Examples

      # Simple step with no parameters
      defstep "I am on the login page" do
        # Setup logic
        %{page: :login}
      end

      # Step with string parameter
      defstep "I enter {string} in the username field", context do
        username = List.first(context.args)
        {:ok, %{username: username}}
      end

      # Step with docstring
      defstep "I submit the following comment:", context do
        # Access the docstring
        comment_text = context.docstring
        {:ok, %{comment: comment_text}}
      end
  """
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
