defmodule Gherkin.Tables do
  @moduledoc false
  # Table checks shared by the `.feature` and `.feature.md` parsers.
  #
  # Every row of a table must have as many cells as its first row, as the
  # reference Gherkin parser requires ("inconsistent cell count"). Without
  # this check a short row silently loses values: `context.datatable.maps`
  # and Examples substitution both zip rows against the header, and
  # `Enum.zip/2` stops at the shorter list.

  alias Gherkin.{Background, Examples, Feature, Rule, ScenarioOutline}

  @doc false
  # Raises `Gherkin.ParseError` at the first row whose cell count differs
  # from its table's first row; returns the feature unchanged otherwise.
  @spec validate!(Feature.t()) :: Feature.t()
  def validate!(%Feature{} = feature) do
    Enum.each(feature.rules, &validate_rule/1)
    validate_container(feature)
    feature
  end

  defp validate_rule(%Rule{} = rule), do: validate_container(rule)

  defp validate_container(%{background: background, scenarios: scenarios}) do
    validate_background(background)
    Enum.each(scenarios, &validate_scenario/1)
  end

  defp validate_background(nil), do: :ok
  defp validate_background(%Background{steps: steps}), do: validate_steps(steps)

  defp validate_scenario(%ScenarioOutline{steps: steps, examples: examples}) do
    validate_steps(steps)
    Enum.each(examples, &validate_examples/1)
  end

  defp validate_scenario(%{steps: steps}), do: validate_steps(steps)

  defp validate_steps(steps) do
    Enum.each(steps, fn step ->
      if step.datatable, do: validate_rows(step.datatable, step.datatable_lines)
    end)
  end

  defp validate_examples(%Examples{table_header: header} = examples)
       when is_list(header) and header != [] do
    validate_rows(
      [header | examples.table_body],
      [examples.table_header_line | examples.table_body_lines || []]
    )
  end

  defp validate_examples(_examples), do: :ok

  defp validate_rows([first | _] = rows, lines) do
    expected = length(first)

    rows
    |> Enum.zip(lines)
    |> Enum.find(fn {cells, _line} -> length(cells) != expected end)
    |> case do
      nil ->
        :ok

      {cells, line} ->
        raise Gherkin.ParseError,
          message:
            "a table row with #{expected} #{cells_word(expected)} to match the first row, " <>
              "got #{length(cells)}",
          line: line + 1,
          column: 1,
          rest: "| " <> Enum.join(cells, " | ") <> " |"
    end
  end

  defp cells_word(1), do: "cell"
  defp cells_word(_count), do: "cells"
end
