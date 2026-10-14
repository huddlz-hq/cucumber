defmodule Gherkin.Tables do
  @moduledoc false
  # Table rows, shared by the `.feature` and `.feature.md` parsers.
  #
  # cells/1 splits a row the way the reference Gherkin tokenizer does, and
  # validate!/2 requires every row of a table to have as many cells as its
  # first row ("inconsistent cell count" in the reference parser). Without
  # that check a short row silently loses values: `context.datatable.maps`
  # and Examples substitution both zip rows against the header, and
  # `Enum.zip/2` stops at the shorter list.

  alias Gherkin.{Background, Examples, Feature, Rule, ScenarioOutline}

  @doc false
  # Splits a table row into its cells: the text between consecutive `|`s,
  # trimmed. Text before the first `|` and after the last is not a cell.
  # Inside a cell `\|` is a literal pipe, `\\` a backslash and `\n` a
  # newline; any other backslash is kept as written.
  @spec cells(String.t()) :: [String.t()]
  def cells(row) do
    case String.split(row, "|", parts: 2) do
      [_before_first_pipe, rest] -> split_cells(rest, [], [])
      [_no_pipe] -> []
    end
  end

  defp split_cells(<<"|", rest::binary>>, cell, cells),
    do: split_cells(rest, [], [trim_cell(cell) | cells])

  defp split_cells(<<"\\n", rest::binary>>, cell, cells),
    do: split_cells(rest, [cell, ?\n], cells)

  defp split_cells(<<"\\", char, rest::binary>>, cell, cells) when char in [?|, ?\\],
    do: split_cells(rest, [cell, char], cells)

  defp split_cells(<<byte, rest::binary>>, cell, cells),
    do: split_cells(rest, [cell, byte], cells)

  # Whatever follows the last `|` is not a cell.
  defp split_cells(<<>>, _unterminated, cells), do: Enum.reverse(cells)

  # Trims surrounding whitespace but keeps newlines, which can only come
  # from a `\n` escape.
  defp trim_cell(cell) do
    Regex.replace(~r/\A[^\S\n]+|[^\S\n]+\z/u, IO.iodata_to_binary(cell), "")
  end

  @doc false
  # Raises `Gherkin.ParseError` at the first row whose cell count differs
  # from its table's first row; returns the feature unchanged otherwise.
  # `source` is the text the feature's 0-based line numbers index into.
  @spec validate!(Feature.t(), String.t()) :: Feature.t()
  def validate!(%Feature{} = feature, source) do
    Enum.each(feature.rules, &validate_container(&1, source))
    validate_container(feature, source)
    feature
  end

  defp validate_container(%struct{} = container, source) when struct in [Feature, Rule] do
    validate_background(container.background, source)
    Enum.each(container.scenarios, &validate_scenario(&1, source))
  end

  defp validate_background(nil, _source), do: :ok
  defp validate_background(%Background{steps: steps}, source), do: validate_steps(steps, source)

  defp validate_scenario(%ScenarioOutline{steps: steps, examples: examples}, source) do
    validate_steps(steps, source)
    Enum.each(examples, &validate_examples(&1, source))
  end

  defp validate_scenario(%{steps: steps}, source), do: validate_steps(steps, source)

  defp validate_steps(steps, source) do
    Enum.each(steps, fn step ->
      if step.datatable, do: validate_rows(step.datatable, step.datatable_lines, source)
    end)
  end

  defp validate_examples(%Examples{table_header: [_ | _] = header} = examples, source) do
    validate_rows(
      [header | examples.table_body],
      [examples.table_header_line | examples.table_body_lines],
      source
    )
  end

  defp validate_examples(_examples, _source), do: :ok

  defp validate_rows([first | _] = rows, lines, source) do
    expected = length(first)

    rows
    |> Enum.zip(lines)
    |> Enum.find(fn {cells, _line} -> length(cells) != expected end)
    |> case do
      nil -> :ok
      {cells, line} -> raise_cell_count!(expected, length(cells), line, source)
    end
  end

  defp raise_cell_count!(expected, actual, line, source) do
    raw = source |> String.split(~r/\r?\n/) |> Enum.at(line, "")
    trimmed = String.trim_leading(raw)

    raise Gherkin.ParseError,
      message:
        "a table row with #{expected} #{cells_word(expected)} to match the first row, " <>
          "got #{actual}",
      line: line + 1,
      column: String.length(raw) - String.length(trimmed) + 1,
      rest: trimmed |> String.trim_trailing() |> String.slice(0, 50)
  end

  defp cells_word(1), do: "cell"
  defp cells_word(_count), do: "cells"
end
