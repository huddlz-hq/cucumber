defmodule Cucumber.Expression do
  @moduledoc """
  Parser and matcher for Cucumber Expressions used in step definitions.

  Cucumber Expressions are a human-friendly alternative to regular expressions,
  allowing you to define step patterns with typed parameters. This module handles
  compiling these expressions and extracting/converting parameters using NimbleParsec.

  ## Parameter Types

  The following parameter types are supported:

  * `{string}` - Matches quoted strings ("example") and converts to string
  * `{int}` - Matches integers (42, -5) and converts to integer
  * `{float}` - Matches floating point numbers (3.14, -0.5) and converts to float
  * `{word}` - Matches a single word (no whitespace) and converts to string
  * `{atom}` - Matches a word and converts to atom (pending -> :pending)

  ## Advanced Features

  * **Escape sequences**: Use `\\{` and `\\}` for literal braces in patterns
  * **Optional parameters**: Use `{int?}` for optional matching (returns nil if absent)
  * **Alternation**: Use `(click|tap)` to match either word (not captured)

  ## Examples

      # Matching a step with a string parameter
      "I click {string} button" matches "I click \\"Submit\\" button"

      # Matching a step with multiple parameters
      "I add {int} items to my {word} list" matches "I add 5 items to my shopping list"

      # Optional parameter
      "I have {int?} items" matches both "I have 5 items" and "I have items"

      # Alternation
      "I (click|tap) the button" matches "I click the button" or "I tap the button"
  """

  import NimbleParsec

  # ===========================================================================
  # Expression Pattern Parser (parses patterns like "I have {int} items")
  # ===========================================================================

  # Escape sequences: \{ and \}
  escaped_brace =
    choice([
      string("\\{") |> replace("{"),
      string("\\}") |> replace("}")
    ])
    |> unwrap_and_tag(:escaped)

  # Parameter type name (lowercase letters and underscores)
  parameter_type = ascii_string([?a..?z, ?_], min: 1)

  # Optional marker: ?
  optional_marker = ascii_char([??]) |> replace(true)

  # Parameter: {type} or {type?}
  parameter =
    ignore(string("{"))
    |> concat(parameter_type)
    |> concat(optional(optional_marker))
    |> ignore(string("}"))
    |> tag(:parameter)

  # Alternation: (option1|option2|option3)
  alternation_text = utf8_string([{:not, ?|}, {:not, ?)}], min: 1)

  alternation =
    ignore(string("("))
    |> concat(alternation_text)
    |> repeat(ignore(string("|")) |> concat(alternation_text))
    |> ignore(string(")"))
    |> tag(:alternation)

  # Literal: any char that's not special
  literal_char = utf8_char([{:not, ?{}, {:not, ?\\}, {:not, ?(}])

  literal =
    times(literal_char, min: 1)
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:literal)

  # Full expression
  defparsecp(
    :parse_expression,
    repeat(choice([escaped_brace, parameter, alternation, literal]))
    |> eos()
  )

  # ===========================================================================
  # Parameter Type Parsers (parse values from step text)
  # ===========================================================================

  # {string} - parses "quoted content" with escape sequences
  defparsec(
    :parse_string_param,
    ignore(string("\""))
    |> repeat(
      choice([
        string(~S(\")) |> replace(?"),
        string(~S(\\)) |> replace(?\\),
        utf8_char([{:not, ?"}])
      ])
    )
    |> ignore(string("\""))
    |> reduce({List, :to_string, []})
  )

  # {int} - parses -123, 0, 456
  defparsec(
    :parse_int_param,
    optional(ascii_char([?-, ?+]))
    |> ascii_string([?0..?9], min: 1)
    |> reduce({__MODULE__, :to_integer, []})
  )

  # {float} - parses -3.14, 0.5
  defparsec(
    :parse_float_param,
    optional(ascii_char([?-, ?+]))
    |> ascii_string([?0..?9], min: 1)
    |> string(".")
    |> ascii_string([?0..?9], min: 1)
    |> reduce({__MODULE__, :to_float, []})
  )

  # {word} - parses non-whitespace
  defparsec(
    :parse_word_param,
    utf8_string([{:not, ?\s}, {:not, ?\t}, {:not, ?\n}], min: 1)
  )

  # {atom} - parses identifier characters
  defparsec(
    :parse_atom_param,
    utf8_string([?a..?z, ?A..?Z, ?0..?9, ?_, ?@], min: 1)
    |> map({String, :to_atom, []})
  )

  @doc false
  def to_integer(parts), do: parts |> IO.iodata_to_binary() |> String.to_integer()

  @doc false
  def to_float(parts), do: parts |> IO.iodata_to_binary() |> String.to_float()

  # ===========================================================================
  # Public API
  # ===========================================================================

  @param_parsers %{
    "string" => &__MODULE__.parse_string_param/1,
    "int" => &__MODULE__.parse_int_param/1,
    "float" => &__MODULE__.parse_float_param/1,
    "word" => &__MODULE__.parse_word_param/1,
    "atom" => &__MODULE__.parse_atom_param/1
  }

  @doc """
  Compiles a Cucumber Expression pattern into a matchable AST.

  This function transforms a human-readable pattern with typed parameters
  into an AST that can be used for matching step text.

  ## Parameters

  * `pattern` - A string containing a Cucumber Expression pattern

  ## Returns

  Returns a compiled expression (list of AST nodes) that can be passed to `match/2`.

  ## Examples

      iex> compiled = Cucumber.Expression.compile("I have {int} items")
      iex> is_list(compiled)
      true
  """
  def compile(pattern) do
    case parse_expression(pattern) do
      {:ok, ast, "", _, _, _} ->
        normalize_ast(ast)

      {:ok, _, rest, _, _, _} ->
        raise "Failed to parse expression, unexpected: #{inspect(rest)}"

      {:error, reason, _, _, _, _} ->
        raise "Failed to parse expression: #{reason}"
    end
  end

  defp normalize_ast(ast) do
    ast
    |> Enum.map(fn
      {:literal, text} ->
        {:literal, text}

      {:escaped, char} ->
        {:literal, char}

      {:parameter, [type]} ->
        {:parameter, type, get_parser!(type), :required}

      {:parameter, [type, true]} ->
        {:parameter, type, get_parser!(type), :optional}

      {:alternation, options} ->
        {:alternation, options}
    end)
    |> merge_adjacent_literals()
  end

  defp get_parser!(type) do
    case Map.fetch(@param_parsers, type) do
      {:ok, parser} -> parser
      :error -> raise "Unknown parameter type: #{type}"
    end
  end

  # Merge adjacent literals (e.g., from escapes)
  defp merge_adjacent_literals(ast) do
    ast
    |> Enum.reduce([], fn
      {:literal, text}, [{:literal, prev} | rest] ->
        [{:literal, prev <> text} | rest]

      node, acc ->
        [node | acc]
    end)
    |> Enum.reverse()
  end

  @doc """
  Matches a step text against a compiled Cucumber Expression.

  This function attempts to match step text against a compiled Cucumber Expression
  and extracts/converts any parameters if there's a match.

  ## Parameters

  * `text` - The step text to match against the pattern
  * `compiled` - A compiled Cucumber Expression from `compile/1`

  ## Returns

  Returns one of:
  * `{:match, args}` - If the text matches, where `args` is a list of converted parameter values
  * `:no_match` - If the text doesn't match the expression

  ## Examples

      iex> compiled = Cucumber.Expression.compile("I have {int} items")
      iex> Cucumber.Expression.match("I have 42 items", compiled)
      {:match, [42]}
      iex> Cucumber.Expression.match("I have no items", compiled)
      :no_match
  """
  def match(text, compiled) do
    case do_match(text, compiled, []) do
      {:ok, args} -> {:match, args}
      :no_match -> :no_match
    end
  end

  # Success: consumed all text and all AST nodes
  defp do_match("", [], acc), do: {:ok, Enum.reverse(acc)}

  # Empty text with optional parameter - return nil and continue
  defp do_match("", [{:parameter, _type, _parser, :optional} | rest], acc) do
    do_match("", rest, [nil | acc])
  end

  # Failure: leftover AST nodes (non-optional)
  defp do_match("", [_ | _], _acc), do: :no_match

  # Failure: leftover text
  defp do_match(_text, [], _acc), do: :no_match

  # Match literal: binary pattern match on prefix
  defp do_match(text, [{:literal, lit} | rest], acc) do
    lit_size = byte_size(lit)

    case text do
      <<^lit::binary-size(lit_size), remaining::binary>> ->
        do_match(remaining, rest, acc)

      _ ->
        :no_match
    end
  end

  # Match required parameter
  defp do_match(text, [{:parameter, _type, parser, :required} | rest], acc) do
    case parser.(text) do
      {:ok, [value], remaining, _, _, _} ->
        do_match(remaining, rest, [value | acc])

      _ ->
        :no_match
    end
  end

  # Match optional parameter
  defp do_match(text, [{:parameter, _type, parser, :optional} | rest], acc) do
    case parser.(text) do
      {:ok, [value], remaining, _, _, _} ->
        do_match(remaining, rest, [value | acc])

      _ ->
        # Optional failed, add nil and continue without consuming text
        do_match(text, rest, [nil | acc])
    end
  end

  # Match alternation: try each option, first match wins (not captured)
  defp do_match(text, [{:alternation, options} | rest], acc) do
    Enum.find_value(options, :no_match, fn option ->
      opt_size = byte_size(option)

      case text do
        <<^option::binary-size(opt_size), remaining::binary>> ->
          # Don't add to acc - alternation is not captured
          do_match(remaining, rest, acc)

        _ ->
          nil
      end
    end)
  end
end
