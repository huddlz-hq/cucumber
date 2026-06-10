defmodule Cucumber.Runtime do
  @moduledoc """
  Runtime execution of cucumber steps.

  This module handles the step execution lifecycle within a running test:

  1. Each step's text is matched against the step registry to find a definition
  2. Cucumber Expressions are used to extract typed parameters from step text
  3. The step function is invoked with context containing extracted `args`,
     optional `datatable`, and optional `docstring`
  4. Step return values are processed to update the shared context:
     - `:ok` keeps context unchanged
     - A map is merged into context
     - A keyword list is converted to a map and merged
     - `{:ok, data}` unwraps and merges
     - `{:error, reason}` fails the step
  5. On failure, enhanced error messages are generated with step history,
     file locations, and formatted assertion details
  """

  alias Cucumber.Expression

  @doc """
  Executes a step with the given context and step registry.
  """
  @spec execute_step(map(), Gherkin.Step.t(), map()) :: map()
  def execute_step(context, step, step_registry) do
    # Add step to history (ensure it exists first)
    context = Map.put_new(context, :step_history, [])
    context = update_in(context, [:step_history], &(&1 ++ [step]))

    # Find matching step definition
    case find_step_definition(step.text, step_registry) do
      {:ok, {module, metadata}, args, pattern_text} ->
        # Prepare context with step arguments
        context = prepare_context(context, args, step)

        # Execute the step
        try do
          result = apply(module, metadata.function, [context])
          process_step_result(result, context)
        rescue
          e ->
            # Extract meaningful information from the error
            feature_file = Map.get(context, :feature_file, "unknown")
            scenario_name = Map.get(context, :scenario_name, "unknown scenario")
            step_history = Map.get(context, :step_history, [])

            # Create enhanced error with better formatting
            enhanced_error =
              Cucumber.StepError.failed_step(
                step,
                pattern_text,
                format_exception_for_display(e),
                feature_file,
                scenario_name,
                format_step_history_with_status(step_history, step, context)
              )

            reraise enhanced_error, scenario_stacktrace(context, step, __STACKTRACE__)
        end

      {:ambiguous, matches} ->
        feature_file = Map.get(context, :feature_file, "unknown")
        scenario_name = Map.get(context, :scenario_name, "unknown scenario")

        listed =
          for {pattern_text, {module, metadata}, _args} <- matches,
              do: {pattern_text, module, metadata}

        error = Cucumber.AmbiguousStepError.new(step, listed, feature_file, scenario_name)
        :erlang.raise(:error, error, scenario_stacktrace(context, step, current_stacktrace()))

      :error ->
        # Extract context info for better error
        feature_file = Map.get(context, :feature_file, "unknown")
        scenario_name = Map.get(context, :scenario_name, "unknown scenario")
        step_history = Map.get(context, :step_history, [])

        # Use the enhanced error module
        error =
          Cucumber.StepError.missing_step_definition(
            step,
            feature_file,
            scenario_name,
            format_step_history_with_status(step_history, step, context)
          )

        :erlang.raise(:error, error, scenario_stacktrace(context, step, current_stacktrace()))
    end
  end

  defp find_step_definition(step_text, step_registry) do
    matches =
      Enum.flat_map(step_registry, fn {{:expression, pattern_text}, definition} ->
        # Compile pattern on the fly (cached via :persistent_term)
        compiled_pattern = Expression.compile(pattern_text)

        case Expression.match(step_text, compiled_pattern) do
          {:match, args} -> [{pattern_text, definition, args}]
          :no_match -> []
        end
      end)

    case matches do
      [] ->
        :error

      [{pattern_text, definition, args}] ->
        {:ok, definition, args, pattern_text}

      multiple ->
        # Stable listing order regardless of map iteration order
        {:ambiguous, Enum.sort_by(multiple, fn {pattern_text, _, _} -> pattern_text end)}
    end
  end

  # Builds the stacktrace reported for a step failure: the first frame points
  # at the failing step's line in the feature file, followed by the original
  # trace (which leads with the step definition's own frame) minus this
  # module's internal frames.
  defp scenario_stacktrace(context, step, stacktrace) do
    test_module = Map.get(context, :module, Cucumber.Scenario)

    feature_file = Map.get(context, :feature_file, "unknown")

    feature_frame =
      {test_module, :scenario, 1, [file: String.to_charlist(feature_file), line: step.line + 1]}

    [feature_frame | Enum.reject(stacktrace, &match?({__MODULE__, _, _, _}, &1))]
  end

  defp current_stacktrace do
    {:current_stacktrace, trace} = Process.info(self(), :current_stacktrace)
    # Drop Process.info/2 and this function's own frames
    Enum.reject(trace, &match?({Process, _, _, _}, &1))
  end

  defp prepare_context(context, args, step) do
    context
    |> Map.put(:args, args)
    |> add_datatable(step.datatable)
    |> add_docstring(step.docstring, step.docstring_media_type)
  end

  defp add_datatable(context, nil), do: context

  defp add_datatable(context, [headers | [_ | _] = rows] = datatable) do
    table_maps =
      Enum.map(rows, fn row ->
        headers |> Enum.zip(row) |> Map.new()
      end)

    table_data = %{headers: headers, rows: rows, maps: table_maps, raw: datatable}
    Map.put(context, :datatable, table_data)
  end

  defp add_datatable(context, datatable) do
    table_data = %{headers: [], rows: datatable, maps: [], raw: datatable}
    Map.put(context, :datatable, table_data)
  end

  defp add_docstring(context, nil, _media_type), do: context

  defp add_docstring(context, docstring, nil) do
    Map.put(context, :docstring, docstring)
  end

  defp add_docstring(context, docstring, media_type) do
    context
    |> Map.put(:docstring, docstring)
    |> Map.put(:docstring_media_type, media_type)
  end

  defp process_step_result(result, context) do
    case result do
      :ok ->
        context

      %{} = new_context ->
        Map.merge(context, new_context)

      keyword when is_list(keyword) ->
        Map.merge(context, Map.new(keyword))

      {:ok, data} when is_map(data) or is_list(data) ->
        process_step_result(data, context)

      {:error, reason} ->
        raise "Step failed: #{inspect(reason)}"

      other ->
        raise "Invalid step return value: #{inspect(other)}. " <>
                "Expected :ok, a map, a keyword list, or {:ok, data}"
    end
  end

  defp format_exception_for_display(exception) do
    # Format the exception with enhanced readability
    case exception do
      %ExUnit.AssertionError{} = e ->
        format_assertion_error(e)

      %{__struct__: module} = e ->
        if assertion_error_module?(module),
          do: format_assertion_error(e),
          else: Exception.message(e)

      other ->
        inspect(other, pretty: true)
    end
  end

  defp assertion_error_module?(module) do
    module_str = Atom.to_string(module)
    String.ends_with?(module_str, "AssertionError") and Code.ensure_loaded?(module)
  end

  defp format_assertion_error(error) do
    # Extract the most useful parts of assertion errors
    base_message = Exception.message(error)

    # For PhoenixTest errors, enhance the formatting
    if String.contains?(base_message, "Found these elements") do
      lines = String.split(base_message, "\n")

      # Find where HTML elements start
      {before_html, html_and_after} =
        Enum.split_while(lines, fn line ->
          not (String.trim(line) |> String.starts_with?("<"))
        end)

      # Format the message parts
      formatted_before = Enum.join(before_html, "\n")

      # Group and format HTML elements
      formatted_html =
        html_and_after
        |> format_html_elements()
        |> Enum.join("\n")

      formatted_before <> "\n" <> formatted_html
    else
      base_message
    end
  end

  defp format_html_elements(lines) do
    lines
    |> group_html_elements()
    |> Enum.map(&format_single_html_element/1)
    |> Enum.reject(&(&1 == []))
  end

  defp group_html_elements(lines) do
    lines
    |> Enum.reduce({[], []}, &group_line/2)
    |> finalize_groups()
  end

  defp group_line(line, {groups, current}) do
    if html_line?(line) do
      {groups, current ++ [line]}
    else
      finalize_current_group(groups, current)
    end
  end

  defp finalize_current_group(groups, []), do: {groups, []}
  defp finalize_current_group(groups, current), do: {groups ++ [current], []}

  defp finalize_groups({groups, []}), do: groups
  defp finalize_groups({groups, current}), do: groups ++ [current]

  defp html_line?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "<") or String.ends_with?(trimmed, ">")
  end

  defp format_single_html_element(lines) do
    # Format a single HTML element with proper indentation
    lines
    |> Enum.map_join("\n", fn line ->
      "  " <> line
    end)
    # Add blank line after each element
    |> then(&[&1, ""])
  end

  defp format_step_history_with_status(step_history, current_step, context) do
    # Convert step history to include status and context
    step_history
    |> Enum.reverse()
    # Show last 10 steps to avoid clutter
    |> Enum.take(10)
    # Put them back in chronological order
    |> Enum.reverse()
    |> Enum.map(fn step ->
      status = if step == current_step, do: :failed, else: :passed
      {status, step, context}
    end)
  end
end
