defmodule Cucumber.Expression do
  @moduledoc """
  Parser and matcher for Cucumber Expressions used in step definitions.

  Cucumber Expressions are a human-friendly alternative to regular expressions,
  allowing you to define step patterns with typed parameters. This module handles
  compiling these expressions and extracting/converting parameters using NimbleParsec.

  This implementation follows the official Cucumber Expression syntax from
  https://github.com/cucumber/cucumber-expressions

  ## Parameter Types

  The following parameter types are supported:

  * `{string}` - Matches quoted strings ("example") and converts to string
  * `{int}` - Matches integers (42, -5) and converts to integer
  * `{float}` - Matches floating point numbers (3.14, -0.5) and converts to float
  * `{word}` - Matches a single word (no whitespace) and converts to string
  * `{atom}` - Matches a word and converts to atom (pending -> :pending)

  ## Advanced Features

  * **Optional text**: Use `(text)` for optional text that may or may not be present
  * **Alternation**: Use `word1/word2` to match alternative words (not captured)
  * **Optional parameters**: Use `{int?}` for optional matching (returns nil if absent)
  * **Escape sequences**: Use `\\(`, `\\)`, `\\/`, `\\{`, `\\}`, `\\\\` for literal characters

  ## Examples

      # Matching a step with a string parameter
      "I click {string} button" matches "I click \\"Submit\\" button"

      # Matching a step with multiple parameters
      "I add {int} items to my {word} list" matches "I add 5 items to my shopping list"

      # Optional text (for pluralization)
      "I have {int} cucumber(s)" matches "I have 1 cucumber" and "I have 5 cucumbers"

      # Alternation
      "I click/tap the button" matches "I click the button" or "I tap the button"

      # Optional parameter
      "I have {int?} items" matches both "I have 5 items" and "I have items"
  """

  import NimbleParsec

  # ===========================================================================
  # Expression Pattern Parser (parses patterns like "I have {int} items")
  # ===========================================================================

  # Escape sequences: \{, \}, \(, \), \/, \\
  escaped_char =
    choice([
      string("\\{") |> replace("{"),
      string("\\}") |> replace("}"),
      string("\\(") |> replace("("),
      string("\\)") |> replace(")"),
      string("\\/") |> replace("/"),
      string("\\\\") |> replace("\\")
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

  # Optional: (text) - text is optional, not captured
  optional_content = utf8_string([{:not, ?)}], min: 1)

  optional =
    ignore(string("("))
    |> concat(optional_content)
    |> ignore(string(")"))
    |> tag(:optional)

  # Alternation: word1/word2/word3 (no whitespace allowed between alternatives)
  # Excludes \, {, (, ), /, whitespace to avoid conflicts with other patterns
  alternation_word =
    utf8_string(
      [
        {:not, ?/},
        {:not, ?\\},
        {:not, ?\s},
        {:not, ?\t},
        {:not, ?\n},
        {:not, ?{},
        {:not, ?(},
        {:not, ?)}
      ],
      min: 1
    )

  alternation =
    alternation_word
    |> ignore(string("/"))
    |> concat(alternation_word)
    |> repeat(ignore(string("/")) |> concat(alternation_word))
    |> tag(:alternation)

  # Whitespace: treated as literal but parsed separately so alternation can match after spaces
  whitespace = utf8_string([?\s, ?\t, ?\n], min: 1) |> unwrap_and_tag(:literal)

  # Non-whitespace literal: any non-space char that's not special
  # This is separate from whitespace so alternation can match at word boundaries
  non_ws_literal_char =
    utf8_char([{:not, ?{}, {:not, ?\\}, {:not, ?(}, {:not, ?\s}, {:not, ?\t}, {:not, ?\n}])

  non_ws_literal =
    times(non_ws_literal_char, min: 1)
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:literal)

  # Full expression
  # Order matters: try alternation before non_ws_literal so word/word patterns are matched
  defparsecp(
    :parse_expression,
    repeat(choice([escaped_char, parameter, optional, alternation, whitespace, non_ws_literal]))
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

  @typedoc """
  A parameter matcher: either a NimbleParsec parser function (built-in
  types) or a custom-type matcher built from a user-registered regex.
  """
  @type parameter_matcher ::
          function() | {:custom, Regex.t(), non_neg_integer(), function() | nil}

  @type compiled :: [
          {:literal, String.t()}
          | {:parameter, String.t(), parameter_matcher(), :required | :optional}
          | {:optional, String.t()}
          | {:alternation, [String.t()]}
        ]

  @typedoc """
  Custom parameter type definitions, keyed by type name — see
  `Cucumber.ParameterTypes`.
  """
  @type custom_types :: %{
          String.t() => %{required(:regexp) => Regex.t(), optional(atom()) => term()}
        }

  @doc """
  Compiles a Cucumber Expression pattern into a matchable AST.

  This function transforms a human-readable pattern with typed parameters
  into an AST that can be used for matching step text. Custom parameter
  types (see `Cucumber.ParameterTypes`) are passed as the second argument;
  `compile/1` compiles with the built-in types only.

  Raises `Cucumber.UndefinedParameterTypeError` if the pattern references a
  parameter type that is neither built-in nor in `custom_types`.

  ## Examples

      iex> compiled = Cucumber.Expression.compile("I have {int} items")
      iex> is_list(compiled)
      true
  """
  @spec compile(String.t()) :: compiled()
  def compile(pattern), do: compile(pattern, %{})

  @spec compile(String.t(), custom_types()) :: compiled()
  def compile(pattern, custom_types) do
    # The fingerprint includes transform funs: a recompiled support module
    # produces new fun instances, which correctly invalidates cached
    # expressions (relevant under mix test.watch).
    cache_key = {__MODULE__, :compiled, pattern, :erlang.phash2(custom_types)}

    case :persistent_term.get(cache_key, :not_found) do
      :not_found ->
        compiled = do_compile(pattern, custom_types)
        :persistent_term.put(cache_key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  defp do_compile(pattern, custom_types) do
    case parse_expression(pattern) do
      {:ok, ast, "", _, _, _} ->
        normalize_ast(ast, pattern, custom_types)

      {:ok, _, rest, _, _, _} ->
        raise "Failed to parse expression, unexpected: #{inspect(rest)}"

      {:error, reason, _, _, _, _} ->
        raise "Failed to parse expression: #{reason}"
    end
  end

  defp normalize_ast(ast, pattern, custom_types) do
    ast
    |> Enum.map(fn
      {:literal, text} ->
        {:literal, text}

      {:escaped, char} ->
        {:literal, char}

      {:parameter, [type]} ->
        {:parameter, type, get_parser!(type, pattern, custom_types), :required}

      {:parameter, [type, true]} ->
        {:parameter, type, get_parser!(type, pattern, custom_types), :optional}

      {:optional, [text]} ->
        {:optional, text}

      {:alternation, options} ->
        {:alternation, options}
    end)
    |> merge_adjacent_literals()
  end

  defp get_parser!(type, pattern, custom_types) do
    case Map.fetch(@param_parsers, type) do
      {:ok, parser} ->
        parser

      :error ->
        case Map.fetch(custom_types, type) do
          {:ok, definition} -> build_custom_matcher(definition)
          :error -> raise Cucumber.UndefinedParameterTypeError.new(type, pattern)
        end
    end
  end

  # A custom type matches a prefix of the remaining step text via its regex
  # (anchored at the start); the matcher carries the capture-group count so
  # unmatched optional groups can be reported as nil (PCRE drops trailing
  # unmatched groups from plain capture results).
  defp build_custom_matcher(%{regexp: %Regex{} = regexp} = definition) do
    source = Regex.source(regexp)
    prefix_anchored = Regex.compile!("\\A(?:#{source})", Regex.opts(regexp))
    {:custom, prefix_anchored, count_capture_groups(source), Map.get(definition, :transform)}
  end

  @doc false
  # Counts capturing groups in a regex source: plain `(`, named `(?<name>`,
  # `(?'name'`, and `(?P<name>` capture; other `(?...)` constructs don't.
  # Escapes and character classes are skipped. Shared with regex step
  # definition matching in Cucumber.Runtime.
  def count_capture_groups(source), do: count_groups(source, :normal, 0)

  defp count_groups(<<>>, _state, count), do: count
  defp count_groups(<<?\\, _, rest::binary>>, state, count), do: count_groups(rest, state, count)
  defp count_groups(<<?[, rest::binary>>, :normal, count), do: count_groups(rest, :class, count)
  defp count_groups(<<?], rest::binary>>, :class, count), do: count_groups(rest, :normal, count)

  defp count_groups(<<?(, rest::binary>>, :normal, count) do
    case rest do
      <<"?<", c, _::binary>> when c != ?= and c != ?! -> count_groups(rest, :normal, count + 1)
      <<"?'", _::binary>> -> count_groups(rest, :normal, count + 1)
      <<"?P<", _::binary>> -> count_groups(rest, :normal, count + 1)
      <<"?", _::binary>> -> count_groups(rest, :normal, count)
      _ -> count_groups(rest, :normal, count + 1)
    end
  end

  defp count_groups(<<_, rest::binary>>, state, count), do: count_groups(rest, state, count)

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
  @spec match(String.t(), compiled()) :: {:match, [term()]} | :no_match
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

  # Empty text with optional text - skip optional and continue
  defp do_match("", [{:optional, _text} | rest], acc) do
    do_match("", rest, acc)
  end

  # Failure: leftover AST nodes (non-optional)
  defp do_match("", [_ | _], _acc), do: :no_match

  # Failure: leftover text
  defp do_match(_text, [], _acc), do: :no_match

  # Match literal: binary pattern match on prefix
  defp do_match(text, [{:literal, lit} | rest], acc) do
    lit_size = byte_size(lit)

    case text do
      <<^lit::binary-size(^lit_size), remaining::binary>> ->
        do_match(remaining, rest, acc)

      _ ->
        :no_match
    end
  end

  # Match required parameter
  defp do_match(text, [{:parameter, _type, parser, :required} | rest], acc) do
    case match_parameter(parser, text) do
      {:ok, value, remaining} ->
        do_match(remaining, rest, [value | acc])

      :no_match ->
        :no_match
    end
  end

  # Match optional parameter
  defp do_match(text, [{:parameter, _type, parser, :optional} | rest], acc) do
    case match_parameter(parser, text) do
      {:ok, value, remaining} ->
        do_match(remaining, rest, [value | acc])

      :no_match ->
        # Optional failed, add nil and continue without consuming text
        do_match(text, rest, [nil | acc])
    end
  end

  # Match optional: text may or may not be present (not captured)
  defp do_match(text, [{:optional, opt_text} | rest], acc) do
    opt_size = byte_size(opt_text)

    case text do
      <<^opt_text::binary-size(^opt_size), remaining::binary>> ->
        # Text present - consume it and continue
        do_match(remaining, rest, acc)

      _ ->
        # Text absent - continue without consuming
        do_match(text, rest, acc)
    end
  end

  # Match alternation: try each option, first match wins (not captured)
  defp do_match(text, [{:alternation, options} | rest], acc) do
    Enum.find_value(options, :no_match, fn option ->
      opt_size = byte_size(option)

      case text do
        <<^option::binary-size(^opt_size), remaining::binary>> ->
          # Don't add to acc - alternation is not captured
          do_match(remaining, rest, acc)

        _ ->
          nil
      end
    end)
  end

  defp match_parameter(parser, text) when is_function(parser) do
    case parser.(text) do
      {:ok, [value], remaining, _, _, _} -> {:ok, value, remaining}
      _ -> :no_match
    end
  end

  defp match_parameter({:custom, prefix_anchored, group_count, transform}, text) do
    capture_spec = [0 | Enum.to_list(1..group_count//1)]

    case :re.run(text, prefix_anchored.re_pattern, [{:capture, capture_spec, :index}]) do
      :nomatch ->
        :no_match

      {:match, [{0, full_length} | group_indexes]} ->
        full_match = binary_part(text, 0, full_length)
        remaining = binary_part(text, full_length, byte_size(text) - full_length)

        group_values =
          Enum.map(group_indexes, fn
            {-1, 0} -> nil
            {start, length} -> binary_part(text, start, length)
          end)

        {:ok, transform_value(transform, full_match, group_values), remaining}
    end
  end

  # No transform: the parameter yields the full matched string. With a
  # transform: no capture groups pass the full match; capture groups pass
  # one argument per group.
  defp transform_value(nil, full_match, _group_values), do: full_match
  defp transform_value(transform, full_match, []), do: transform.(full_match)
  defp transform_value(transform, _full_match, group_values), do: apply(transform, group_values)
end
