defmodule Cucumber.Runtime do
  @moduledoc """
  Runtime execution of cucumber steps.
  """

  alias Cucumber.Expression

  @doc """
  Executes a step with the given context and step registry.
  """
  def execute_step(context, step, step_registry) do
    # Add step to history (ensure it exists first)
    context = Map.put_new(context, :step_history, [])
    context = update_in(context, [:step_history], &(&1 ++ [step]))

    # Find matching step definition
    case find_step_definition(step.text, step_registry) do
      {:ok, {module, _metadata}, args} ->
        # Prepare context with step arguments
        context = prepare_context(context, args, step)

        # Execute the step
        try do
          result = module.step(context, step.text)
          process_step_result(result, context)
        rescue
          e ->
            # Re-raise with more context
            reraise e, __STACKTRACE__
        end

      :error ->
        # Generate undefined step error
        raise "Undefined step: '#{step.text}'\n\n" <>
                "You can implement it by adding this to one of your step definition files:\n\n" <>
                "step \"#{step.text}\", context do\n" <>
                "  # TODO: Write implementation\n" <>
                "  context\n" <>
                "end"
    end
  end

  defp find_step_definition(step_text, step_registry) do
    # Try to match against each registered pattern
    Enum.find_value(step_registry, :error, fn {pattern, definition} ->
      case Expression.match(step_text, pattern) do
        {:match, args} -> {:ok, definition, args}
        :no_match -> nil
      end
    end)
  end

  defp prepare_context(context, args, step) do
    context
    |> Map.put(:args, args)
    |> add_datatable(step.datatable)
    |> add_docstring(step.docstring)
  end

  defp add_datatable(context, nil), do: context

  defp add_datatable(context, datatable) do
    # Convert datatable to list of maps
    [headers | rows] = datatable

    table_data =
      Enum.map(rows, fn row ->
        headers
        |> Enum.zip(row)
        |> Map.new()
      end)

    Map.put(context, :datatable, table_data)
  end

  defp add_docstring(context, nil), do: context

  defp add_docstring(context, docstring) do
    Map.put(context, :docstring, docstring)
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
end
