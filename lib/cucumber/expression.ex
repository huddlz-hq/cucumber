defmodule Cucumber.Expression do
  @moduledoc """
  Parser for Cucumber Expressions.

  Supports the following parameter types:
  - {string} - Matches quoted strings and converts to string
  - {int} - Matches integers and converts to integer
  - {float} - Matches floating point numbers and converts to float
  - {word} - Matches a single word (no whitespace) and converts to string

  Example:
  "I click {string} on the {word} event"
  """

  @doc """
  Compiles a Cucumber Expression pattern into a regex and parameter converters.

  Returns `{regex, converters}` where:
  - `regex` is a compiled regular expression for matching step text
  - `converters` is a list of functions to convert captured values
  """
  def compile(pattern) do
    # Define parameter type patterns and converters
    parameter_types = %{
      "string" => {~s/"([^"]*)"/, & &1},
      "int" => {~s/(-?\\d+)/, &String.to_integer/1},
      "float" => {~s/(-?\\d+\\.\\d+)/, &String.to_float/1},
      "word" => {~s/([^\\s]+)/, & &1}
    }

    # Find parameter placeholders like {string}, {int}, etc.
    placeholder_regex = ~r/\{([^}]+)\}/

    # Replace parameter placeholders with their regex patterns and collect converters
    {regex_pattern, converters} =
      Regex.split(placeholder_regex, pattern, include_captures: true)
      |> Enum.reduce({"", []}, fn
        "{" <> rest, {pattern_acc, converters_acc} ->
          # Extract the parameter type from the capture (remove the trailing "}")
          type = String.replace(rest, "}", "")

          case Map.get(parameter_types, type) do
            {regex_part, converter} ->
              {pattern_acc <> regex_part, converters_acc ++ [converter]}

            nil ->
              raise "Unknown parameter type: #{type}"
          end

        plain_text, {pattern_acc, converters_acc} ->
          # Escape regex special characters in plain text
          escaped = Regex.escape(plain_text)
          {pattern_acc <> escaped, converters_acc}
      end)

    # Compile the final regex pattern
    regex = Regex.compile!("^#{regex_pattern}$")

    {regex, converters}
  end

  @doc """
  Matches a step text against a compiled Cucumber Expression.

  Returns `{:match, args}` if the text matches, where `args` is a list of
  converted parameter values.

  Returns `:no_match` if the text doesn't match.
  """
  def match(text, {regex, converters}) do
    case Regex.run(regex, text, capture: :all_but_first) do
      nil ->
        :no_match

      captures ->
        # Apply converters to captured values
        args =
          Enum.zip(captures, converters)
          |> Enum.map(fn {value, converter} -> converter.(value) end)

        {:match, args}
    end
  end
end
