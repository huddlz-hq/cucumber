defmodule Gherkin.NimbleParser do
  @moduledoc """
  NimbleParsec-based Gherkin parser.

  This module provides a compiled parser for Gherkin feature files using NimbleParsec.
  It produces the same output structs as the original parser for backward compatibility.

  ## Architecture

  The parser is built bottom-up in levels:
  - Level 1: Primitives (whitespace, newlines, rest_of_line)
  - Level 2: Keywords (Given, When, Then, Feature:, etc.)
  - Level 3: Elements (tags, datatables, docstrings)
  - Level 4: Steps (keyword + text + optional attachments)
  - Level 5: Scenarios (Background, Scenario, ScenarioOutline, Examples)
  - Level 6: Feature (top-level parser)
  """

  import NimbleParsec

  alias Gherkin.{Background, Examples, Feature, Scenario, ScenarioOutline, Step}

  # ============================================================
  # LEVEL 1: PRIMITIVES
  # ============================================================

  # Horizontal whitespace (spaces and tabs only)
  horizontal_ws = ascii_string([?\s, ?\t], min: 1)

  # Optional horizontal whitespace
  optional_ws = ignore(optional(horizontal_ws))

  # Newline handling (Windows \r\n and Unix \n)
  newline = choice([string("\r\n"), string("\n")])

  # End of line (newline or end of string)
  eol = choice([ignore(newline), eos()])

  # Rest of line (everything until newline), trimmed
  rest_of_line =
    utf8_string([not: ?\n, not: ?\r], min: 0)
    |> map({String, :trim, []})

  # Blank line (optional whitespace followed by newline)
  blank_line =
    optional_ws
    |> concat(newline)
    |> ignore()

  # Zero or more blank lines
  blank_lines = repeat(blank_line)

  # ============================================================
  # LEVEL 2: KEYWORDS
  # ============================================================

  # Step keywords (case-sensitive per Gherkin spec)
  step_keyword =
    choice([
      string("Given"),
      string("When"),
      string("Then"),
      string("And"),
      string("But"),
      string("*")
    ])
    |> label("step keyword (Given, When, Then, And, But, or *)")

  # Section keywords
  feature_keyword =
    string("Feature:")
    |> label("Feature:")

  background_keyword =
    string("Background:")
    |> label("Background:")

  scenario_keyword =
    string("Scenario:")
    |> label("Scenario:")

  scenario_outline_keyword =
    choice([string("Scenario Outline:"), string("Scenario Template:")])
    |> label("Scenario Outline:")

  examples_keyword =
    choice([string("Examples:"), string("Scenarios:")])
    |> label("Examples:")

  # ============================================================
  # LEVEL 3: ELEMENTS
  # ============================================================

  # --- Tags ---
  # Single tag: @tag_name
  tag =
    ignore(string("@"))
    |> utf8_string([?a..?z, ?A..?Z, ?0..?9, ?_, ?-], min: 1)
    |> label("tag name")

  # Tag line: @tag1 @tag2 @tag3
  tag_line =
    optional_ws
    |> concat(tag)
    |> repeat(
      ignore(horizontal_ws)
      |> concat(tag)
    )
    |> concat(eol)
    |> wrap()
    |> label("tag line")

  # Multiple tag lines (before features, scenarios, examples)
  tags =
    repeat(tag_line)
    |> reduce({__MODULE__, :flatten_tags, []})

  # --- Data Tables ---
  # Table cell: | followed by content (not including the next |)
  # A row like "| a | b |" has cells at each | delimiter
  # The last | before newline creates an empty cell which we filter out
  table_cell =
    ignore(string("|"))
    |> ignore(optional(horizontal_ws))
    |> utf8_string([not: ?|, not: ?\n, not: ?\r], min: 0)
    |> map({String, :trim, []})

  # Table row: | cell1 | cell2 | cell3 |
  # Note: times(table_cell, min: 1) will consume the trailing | as an empty cell
  table_row =
    optional_ws
    |> times(table_cell, min: 1)
    |> concat(eol)
    |> reduce({__MODULE__, :filter_table_cells, []})
    |> label("table row")

  # Full data table
  datatable =
    times(table_row, min: 1)
    |> tag(:datatable)
    |> label("data table")

  # --- DocStrings ---
  docstring_delimiter = string(~s("""))

  # Content line (anything that's not the closing delimiter)
  docstring_content_line =
    lookahead_not(
      optional_ws
      |> concat(docstring_delimiter)
    )
    |> concat(utf8_string([not: ?\n, not: ?\r], min: 0))
    |> ignore(newline)

  # Full docstring
  docstring =
    optional_ws
    |> ignore(docstring_delimiter)
    |> concat(eol)
    |> repeat(docstring_content_line)
    |> concat(optional_ws)
    |> ignore(docstring_delimiter)
    |> concat(eol)
    |> reduce({__MODULE__, :join_docstring, []})
    |> unwrap_and_tag(:docstring)
    |> label("docstring")

  # ============================================================
  # LEVEL 4: STEPS
  # ============================================================

  # Step text (everything after keyword until end of line)
  step_text =
    ignore(horizontal_ws)
    |> concat(rest_of_line)

  # Section markers that stop step parsing
  section_marker =
    optional_ws
    |> choice([
      scenario_keyword,
      scenario_outline_keyword,
      examples_keyword,
      # Tag line indicates new section
      string("@")
    ])

  # Complete step with optional docstring/datatable attachment
  step =
    lookahead_not(section_marker)
    |> concat(optional_ws)
    |> line(concat(step_keyword, step_text))
    |> concat(eol)
    |> optional(choice([docstring, datatable]))
    |> reduce({__MODULE__, :build_step, []})
    |> label("step")

  # Multiple steps (also skip blank lines between steps)
  steps =
    repeat(
      choice([
        step,
        lookahead_not(section_marker) |> concat(blank_line)
      ])
    )
    |> reduce({__MODULE__, :filter_steps, []})

  # ============================================================
  # LEVEL 5: SCENARIOS
  # ============================================================

  # --- Background ---
  # Background section name (optional text after Background:)
  background_name =
    ignore(background_keyword)
    |> concat(rest_of_line)
    |> concat(eol)

  # Background parser
  background =
    optional_ws
    |> concat(background_name)
    |> ignore(blank_lines)
    |> concat(steps |> tag(:steps))
    |> reduce({__MODULE__, :build_background, []})
    |> unwrap_and_tag(:background)
    |> label("background section")

  # --- Examples ---
  examples_name =
    ignore(examples_keyword)
    |> concat(rest_of_line)

  # Lookahead to verify Examples: keyword follows tags
  examples_lookahead =
    lookahead(
      repeat(tag_line)
      |> concat(optional_ws)
      |> concat(examples_keyword)
    )

  # Examples block (tags + name + table)
  examples_block =
    ignore(blank_lines)
    |> concat(examples_lookahead)
    |> concat(tags |> tag(:tags))
    |> concat(optional_ws)
    |> line(examples_name)
    |> concat(eol)
    |> ignore(blank_lines)
    |> concat(times(table_row, min: 1) |> tag(:table))
    |> reduce({__MODULE__, :build_examples, []})
    |> label("examples block")

  # --- Scenario ---
  scenario_name =
    ignore(scenario_keyword)
    |> concat(rest_of_line)

  # Regular scenario parser
  scenario =
    tags
    |> tag(:tags)
    |> concat(optional_ws)
    |> line(scenario_name)
    |> concat(eol)
    |> ignore(blank_lines)
    |> concat(steps |> tag(:steps))
    |> reduce({__MODULE__, :build_scenario, []})
    |> label("scenario")

  # --- Scenario Outline ---
  outline_name =
    ignore(scenario_outline_keyword)
    |> concat(rest_of_line)

  # Scenario outline with examples
  scenario_outline =
    tags
    |> tag(:tags)
    |> concat(optional_ws)
    |> line(outline_name)
    |> concat(eol)
    |> ignore(blank_lines)
    |> concat(steps |> tag(:steps))
    |> concat(times(examples_block, min: 1) |> tag(:examples))
    |> reduce({__MODULE__, :build_scenario_outline, []})
    |> label("scenario outline")

  # Scenario or scenario outline
  scenario_definition =
    ignore(blank_lines)
    |> choice([
      scenario_outline,
      scenario
    ])

  # ============================================================
  # LEVEL 6: FEATURE
  # ============================================================

  # Feature name
  feature_name =
    ignore(feature_keyword)
    |> ignore(optional(horizontal_ws))
    |> concat(rest_of_line)
    |> concat(eol)

  # Feature description (lines between feature name and first scenario/background)
  # A description line is any line that's not a section start or tag
  description_line =
    lookahead_not(
      optional_ws
      |> choice([
        background_keyword,
        scenario_keyword,
        scenario_outline_keyword,
        string("@")
      ])
    )
    |> concat(rest_of_line)
    |> concat(eol)
    |> ignore()

  # Full feature file parser
  feature =
    ignore(blank_lines)
    |> concat(tags |> tag(:tags))
    |> concat(optional_ws)
    |> concat(feature_name |> unwrap_and_tag(:name))
    |> ignore(repeat(choice([blank_line, description_line])))
    |> optional(background)
    |> concat(repeat(scenario_definition) |> tag(:scenarios))
    |> reduce({__MODULE__, :build_feature, []})
    |> label("feature")

  # ============================================================
  # PUBLIC API
  # ============================================================

  defparsec(:parse_feature, feature)

  @doc """
  Parses a Gherkin feature file string into structured data.

  Returns a `%Gherkin.Feature{}` struct on success.
  Raises `Gherkin.ParseError` on failure.
  """
  def parse(gherkin_string) do
    # Strip leading newline that heredoc strings add
    normalized = String.trim_leading(gherkin_string, "\n")

    case parse_feature(normalized) do
      {:ok, [feature], "", _context, _line, _offset} ->
        feature

      {:ok, [feature], _rest, _context, _line, _offset} ->
        # Partial parse - return what we have
        feature

      {:error, message, rest, _context, {line, col}, _offset} ->
        raise Gherkin.ParseError,
          message: message,
          line: line,
          column: col,
          rest: String.slice(rest, 0, 50)
    end
  end

  # ============================================================
  # BUILD HELPERS (post_traverse callbacks)
  # ============================================================

  @doc false
  def join_docstring(lines) do
    # Find minimum indentation of non-empty lines
    min_indent =
      lines
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&count_leading_spaces/1)
      |> Enum.min(fn -> 0 end)

    # Strip baseline indentation from each line
    lines
    |> Enum.map_join("\n", &strip_indent(&1, min_indent))
    |> String.trim_trailing()
  end

  defp count_leading_spaces(line) do
    line
    |> String.graphemes()
    |> Enum.take_while(&(&1 == " " or &1 == "\t"))
    |> length()
  end

  defp strip_indent(line, amount) when amount > 0 do
    String.slice(line, amount, String.length(line))
  end

  defp strip_indent(line, _amount), do: line

  @doc false
  def filter_steps(items) do
    Enum.filter(items, &is_struct(&1, Step))
  end

  @doc false
  def filter_table_cells(cells) do
    # Remove trailing empty cell created by the final |
    cells
    |> Enum.reject(&(&1 == ""))
  end

  @doc false
  def flatten_tags(tag_lines) do
    # tag_lines is a list of lists (each tag_line is wrapped)
    # Flatten to a single list of tag strings
    tag_lines
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
  end

  @doc false
  def build_step(args) do
    # args structure: [{[keyword, text], {line, _offset}}, optional_attachment]
    {step_data, attachment} = extract_step_parts(args)
    {[keyword, text], {line_num, _offset}} = step_data

    {docstring, datatable} =
      case attachment do
        {:docstring, ds} -> {ds, nil}
        {:datatable, dt} -> {nil, dt}
        nil -> {nil, nil}
      end

    %Step{
      keyword: keyword,
      text: text,
      docstring: docstring,
      datatable: datatable,
      line: line_num - 1
    }
  end

  defp extract_step_parts([{_data, {_line, _offset}} = step_data]) do
    {step_data, nil}
  end

  defp extract_step_parts([{_data, {_line, _offset}} = step_data, attachment]) do
    {step_data, attachment}
  end

  @doc false
  def build_background(args) do
    steps = extract_tagged(args, :steps)

    %Background{
      steps: steps
    }
  end

  @doc false
  def build_examples(args) do
    tags = extract_tagged(args, :tags)
    table = extract_tagged(args, :table)
    {name, line_num} = extract_examples_name(args)

    [header | body] = table

    %Examples{
      name: name,
      tags: tags,
      table_header: header,
      table_body: body,
      line: if(line_num, do: line_num - 1, else: nil)
    }
  end

  defp extract_examples_name(args) do
    case args do
      [{:tags, _} | rest] -> extract_examples_name(rest)
      [{:table, _} | rest] -> extract_examples_name(rest)
      [{[name], {line, _offset}} | _] -> {String.trim(name), line}
      [{name, {line, _offset}} | _] when is_binary(name) -> {String.trim(name), line}
      [[name] | _] when is_binary(name) -> {String.trim(name), nil}
      [name | _] when is_binary(name) -> {String.trim(name), nil}
      _ -> {"", nil}
    end
  end

  @doc false
  def build_scenario(args) do
    tags = extract_tagged(args, :tags)
    steps = extract_tagged(args, :steps)
    {name, line_num} = extract_scenario_name(args)

    %Scenario{
      name: name,
      steps: steps,
      tags: tags,
      line: if(line_num, do: line_num - 1, else: nil)
    }
  end

  defp extract_scenario_name(args) do
    case args do
      [{:tags, _} | rest] -> extract_scenario_name(rest)
      [{:steps, _} | rest] -> extract_scenario_name(rest)
      [{:examples, _} | rest] -> extract_scenario_name(rest)
      [{[name], {line, _offset}} | _] -> {String.trim(name), line}
      [{name, {line, _offset}} | _] when is_binary(name) -> {String.trim(name), line}
      _ -> {"", nil}
    end
  end

  @doc false
  def build_scenario_outline(args) do
    tags = extract_tagged(args, :tags)
    steps = extract_tagged(args, :steps)
    examples = extract_tagged(args, :examples)
    {name, line_num} = extract_scenario_name(args)

    %ScenarioOutline{
      name: name,
      steps: steps,
      tags: tags,
      examples: examples,
      line: if(line_num, do: line_num - 1, else: nil)
    }
  end

  @doc false
  def build_feature(args) do
    tags = extract_tagged(args, :tags)
    name = extract_tagged_single(args, :name) || ""
    background = extract_tagged_single(args, :background)
    scenarios = extract_tagged(args, :scenarios)

    %Feature{
      name: name,
      description: "",
      tags: tags,
      background: background,
      scenarios: scenarios
    }
  end

  # Extract tagged values from args list (returns list)
  # For :table, we need to preserve row structure
  defp extract_tagged(args, tag) do
    case Enum.find(args, fn
           {^tag, _} -> true
           _ -> false
         end) do
      {^tag, values} when tag == :table ->
        # Table rows: unwrap one level but preserve row structure
        case values do
          [rows] when is_list(rows) and is_list(hd(rows)) -> rows
          rows -> rows
        end

      {^tag, values} ->
        List.flatten([values])

      nil ->
        []
    end
  end

  # Extract single tagged value (returns value or nil)
  defp extract_tagged_single(args, tag) do
    case Enum.find(args, fn
           {^tag, _} -> true
           _ -> false
         end) do
      {^tag, value} when is_list(value) -> List.first(value)
      {^tag, value} -> value
      nil -> nil
    end
  end
end

defmodule Gherkin.ParseError do
  @moduledoc """
  Exception raised when parsing a Gherkin file fails.

  Contains detailed information about the parse error including
  line number, column, and context.
  """

  defexception [:message, :line, :column, :rest]

  @impl true
  def message(%{message: msg, line: line, column: col, rest: rest}) do
    snippet = if rest && rest != "", do: ~s(\nNear: "#{rest}..."), else: ""

    """
    Gherkin parse error at line #{line}, column #{col}:
      Expected #{msg}#{snippet}
    """
  end
end
