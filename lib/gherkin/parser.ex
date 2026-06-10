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

  alias Gherkin.{Background, Examples, Feature, Rule, Scenario, ScenarioOutline, Step}

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

  # Comment line (optional whitespace, then # and the rest of the line).
  # Gherkin treats these as content-less, so we skip them anywhere a blank line is valid.
  comment_line =
    optional_ws
    |> concat(string("#"))
    |> concat(utf8_string([not: ?\n, not: ?\r], min: 0))
    |> concat(eol)
    |> ignore()

  # Non-content line: blank or comment. Both are skipped between meaningful tokens.
  skippable_line = choice([blank_line, comment_line])

  # Zero or more blank or comment lines
  blank_lines = repeat(skippable_line)

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

  # "Example:" is the spec synonym for "Scenario:". No conflict with
  # "Examples:" — the colon position differs, so neither prefix-matches
  # the other.
  scenario_keyword =
    choice([string("Scenario:"), string("Example:")])
    |> label("Scenario:")

  rule_keyword =
    string("Rule:")
    |> label("Rule:")

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

  # Multiple tag lines (before features, scenarios, examples).
  # Blank and comment lines may be interspersed (e.g. between two @tag lines,
  # or between the last @tag and the following keyword). flatten_tags filters
  # to binaries so skippable_line's empty output is harmless.
  tags =
    repeat(choice([tag_line, skippable_line]))
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
  # Gherkin supports two docstring delimiters: """ and ``` (backticks).
  # The closing delimiter must match the opening one, so each delimiter gets
  # its own combinator — which also makes the other delimiter style plain
  # content for free. An optional media type (e.g. json in ```json) may
  # follow the opening delimiter.
  docstring_for = fn delimiter ->
    # Content line (anything that's not this docstring's closing delimiter)
    content_line =
      lookahead_not(
        optional_ws
        |> concat(string(delimiter))
      )
      |> concat(utf8_string([not: ?\n, not: ?\r], min: 0))
      |> ignore(newline)

    optional_ws
    |> ignore(string(delimiter))
    |> concat(rest_of_line |> unwrap_and_tag(:media_type))
    |> concat(eol)
    |> repeat(content_line)
    |> concat(optional_ws)
    |> ignore(string(delimiter))
    |> concat(eol)
  end

  docstring =
    choice([docstring_for.(~s(""")), docstring_for.("```")])
    |> reduce({__MODULE__, :build_docstring, []})
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
      rule_keyword,
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

  # Multiple steps (also skip blank/comment lines between steps)
  steps =
    repeat(
      choice([
        step,
        lookahead_not(section_marker) |> concat(skippable_line)
      ])
    )
    |> reduce({__MODULE__, :filter_steps, []})

  # ============================================================
  # LEVEL 4.5: DESCRIPTIONS
  # ============================================================
  # Free-form description text may follow any section header (Feature:,
  # Background:, Scenario:, Scenario Outline:, Examples:) until the first
  # step, tag, table row, docstring, or next section keyword. Blank lines
  # are part of the description region (captured as empty lines); comment
  # lines are skipped. The builder dedents and trims the collected lines.

  # A description line must consume at least one byte — content or a bare
  # newline — or repeat() would loop forever on a zero-width match at the
  # end of input.
  description_line_content =
    choice([
      utf8_string([not: ?\n, not: ?\r], min: 1) |> concat(eol),
      newline |> replace("")
    ])

  # At feature level there are no steps yet, so lines starting with step
  # keywords (including * bullets) are still description.
  feature_description_line =
    lookahead_not(
      optional_ws
      |> choice([
        background_keyword,
        scenario_keyword,
        scenario_outline_keyword,
        examples_keyword,
        rule_keyword,
        string("@")
      ])
    )
    |> lookahead_not(optional_ws |> concat(string("#")))
    |> concat(description_line_content)

  feature_description =
    repeat(choice([comment_line, feature_description_line]))
    |> reduce({__MODULE__, :build_description, []})
    |> unwrap_and_tag(:description)

  # Inside a section, a line starting with a step keyword belongs to the
  # steps (the keyword must be followed by whitespace, so words like
  # "Givenness" stay description). Table rows and docstring delimiters
  # terminate the description so malformed placement still errors.
  section_description_line =
    lookahead_not(
      optional_ws
      |> choice([
        step_keyword |> concat(horizontal_ws),
        background_keyword,
        scenario_keyword,
        scenario_outline_keyword,
        examples_keyword,
        rule_keyword,
        string("@"),
        string("|"),
        string(~s(""")),
        string("```")
      ])
    )
    |> lookahead_not(optional_ws |> concat(string("#")))
    |> concat(description_line_content)

  section_description =
    repeat(choice([comment_line, section_description_line]))
    |> reduce({__MODULE__, :build_description, []})
    |> unwrap_and_tag(:description)

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
    |> concat(section_description)
    |> concat(steps |> tag(:steps))
    |> reduce({__MODULE__, :build_background, []})
    |> unwrap_and_tag(:background)
    |> label("background section")

  # --- Examples ---
  examples_name =
    ignore(examples_keyword)
    |> concat(rest_of_line)

  # Lookahead to verify Examples: keyword follows tags (with optional
  # interspersed blank/comment lines, matching the `tags` combinator above).
  examples_lookahead =
    lookahead(
      repeat(choice([tag_line, skippable_line]))
      |> concat(optional_ws)
      |> concat(examples_keyword)
    )

  # Examples block (tags + name + description + table)
  examples_block =
    ignore(blank_lines)
    |> concat(examples_lookahead)
    |> concat(tags |> tag(:tags))
    |> concat(optional_ws)
    |> line(examples_name)
    |> concat(eol)
    |> concat(section_description)
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
    |> concat(section_description)
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
    |> concat(section_description)
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

  # --- Rule ---
  rule_name =
    ignore(rule_keyword)
    |> concat(rest_of_line)

  # A rule groups scenarios and may carry its own background. Scenarios
  # following a Rule: header belong to that rule (rules cannot be "closed",
  # so each rule's repeat consumes everything until the next Rule: or EOF).
  rule =
    ignore(blank_lines)
    |> concat(tags |> tag(:tags))
    |> concat(optional_ws)
    |> line(rule_name)
    |> concat(eol)
    |> concat(section_description)
    |> optional(background)
    |> concat(repeat(scenario_definition) |> tag(:scenarios))
    |> reduce({__MODULE__, :build_rule, []})
    |> label("rule section")

  # ============================================================
  # LEVEL 6: FEATURE
  # ============================================================

  # Feature name
  feature_name =
    ignore(feature_keyword)
    |> ignore(optional(horizontal_ws))
    |> concat(rest_of_line)
    |> concat(eol)

  # Full feature file parser
  feature =
    ignore(blank_lines)
    |> concat(tags |> tag(:tags))
    |> concat(optional_ws)
    |> concat(feature_name |> unwrap_and_tag(:name))
    |> concat(feature_description)
    |> optional(background)
    |> concat(repeat(scenario_definition) |> tag(:scenarios))
    |> concat(repeat(rule) |> tag(:rules))
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

      {:ok, [feature], rest, _context, {line, col}, _offset} ->
        # Trailing whitespace is benign; non-whitespace content means the
        # parser silently stopped mid-file (e.g. on a malformed line).
        # Raising prevents scenarios from being dropped without notice.
        if String.trim(rest) == "" do
          feature
        else
          raise Gherkin.ParseError,
            message: "Unexpected content; parser stopped before end of file",
            line: line,
            column: col,
            rest: String.slice(rest, 0, 80)
        end

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
  # Builds the {content, media_type} pair for a docstring from the parser
  # output: a tagged media type (text after the opening delimiter) followed
  # by the raw content lines.
  def build_docstring([{:media_type, media_type} | lines]) do
    media_type = if media_type == "", do: nil, else: media_type
    {join_docstring(lines), media_type}
  end

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

  @doc false
  # Joins captured description lines: dedents to the minimum indentation of
  # non-blank lines, preserves interior blank lines, and drops leading and
  # trailing blank lines.
  def build_description(lines) do
    lines
    |> Enum.map(&String.trim_trailing/1)
    |> join_docstring()
    |> String.trim_leading("\n")
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

    {docstring, docstring_media_type, datatable} =
      case attachment do
        {:docstring, {content, media_type}} -> {content, media_type, nil}
        {:datatable, dt} -> {nil, nil, dt}
        nil -> {nil, nil, nil}
      end

    %Step{
      keyword: keyword,
      text: text,
      docstring: docstring,
      docstring_media_type: docstring_media_type,
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
      steps: steps,
      description: extract_tagged_single(args, :description) || ""
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
      description: extract_tagged_single(args, :description) || "",
      tags: tags,
      table_header: header,
      table_body: body,
      line: if(line_num, do: line_num - 1, else: nil)
    }
  end

  defp extract_examples_name(args),
    do: extract_name_from_args(args, [:tags, :table, :description])

  defp extract_scenario_name(args),
    do: extract_name_from_args(args, [:tags, :steps, :examples, :description])

  defp extract_rule_name(args),
    do: extract_name_from_args(args, [:tags, :description, :background, :scenarios])

  defp extract_name_from_args([{tag, _} | rest], skip_tags) when is_atom(tag) do
    if tag in skip_tags,
      do: extract_name_from_args(rest, skip_tags),
      else: {"", nil}
  end

  defp extract_name_from_args([{[name], {line, _}} | _], _) when is_binary(name),
    do: {String.trim(name), line}

  defp extract_name_from_args([{name, {line, _}} | _], _) when is_binary(name),
    do: {String.trim(name), line}

  defp extract_name_from_args([[name] | _], _) when is_binary(name),
    do: {String.trim(name), nil}

  defp extract_name_from_args([name | _], _) when is_binary(name),
    do: {String.trim(name), nil}

  defp extract_name_from_args(_, _), do: {"", nil}

  @doc false
  def build_scenario(args) do
    tags = extract_tagged(args, :tags)
    steps = extract_tagged(args, :steps)
    {name, line_num} = extract_scenario_name(args)

    %Scenario{
      name: name,
      description: extract_tagged_single(args, :description) || "",
      steps: steps,
      tags: tags,
      line: if(line_num, do: line_num - 1, else: nil)
    }
  end

  @doc false
  def build_scenario_outline(args) do
    tags = extract_tagged(args, :tags)
    steps = extract_tagged(args, :steps)
    examples = extract_tagged(args, :examples)
    {name, line_num} = extract_scenario_name(args)

    %ScenarioOutline{
      name: name,
      description: extract_tagged_single(args, :description) || "",
      steps: steps,
      tags: tags,
      examples: examples,
      line: if(line_num, do: line_num - 1, else: nil)
    }
  end

  @doc false
  def build_rule(args) do
    tags = extract_tagged(args, :tags)
    scenarios = extract_tagged(args, :scenarios)
    background = extract_tagged_single(args, :background)
    {name, line_num} = extract_rule_name(args)

    %Rule{
      name: name,
      description: extract_tagged_single(args, :description) || "",
      tags: tags,
      background: background,
      scenarios: scenarios,
      line: if(line_num, do: line_num - 1, else: nil)
    }
  end

  @doc false
  def build_feature(args) do
    tags = extract_tagged(args, :tags)
    name = extract_tagged_single(args, :name) || ""
    background = extract_tagged_single(args, :background)
    scenarios = extract_tagged(args, :scenarios)
    rules = extract_tagged(args, :rules)

    %Feature{
      name: name,
      description: extract_tagged_single(args, :description) || "",
      tags: tags,
      background: background,
      scenarios: scenarios,
      rules: rules
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
