defmodule Gherkin.Feature do
  @moduledoc """
  Represents a parsed Gherkin feature file (minimal subset).

  A Feature is the top-level element in a Gherkin file, containing a name,
  optional description, optional background, and one or more scenarios.
  It can also have tags that apply to all scenarios in the feature.
  """
  defstruct name: "", description: "", background: nil, scenarios: [], tags: []

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          background: Gherkin.Background.t() | nil,
          scenarios: [Gherkin.Scenario.t() | Gherkin.ScenarioOutline.t()],
          tags: [String.t()]
        }
end

defmodule Gherkin.Background do
  @moduledoc """
  Represents a Gherkin Background section.

  A Background contains steps that are run before each scenario in the feature.
  It allows you to define common setup steps that apply to all scenarios.
  """
  defstruct steps: []

  @type t :: %__MODULE__{
          steps: [Gherkin.Step.t()]
        }
end

defmodule Gherkin.Scenario do
  @moduledoc """
  Represents a Gherkin Scenario section.

  A Scenario is a concrete example that illustrates a business rule.
  It consists of a name, a list of steps, optional tags for filtering,
  and the line number where it appears in the source file.
  """
  defstruct name: "", steps: [], tags: [], line: nil

  @type t :: %__MODULE__{
          name: String.t(),
          steps: [Gherkin.Step.t()],
          tags: [String.t()],
          line: non_neg_integer() | nil
        }
end

defmodule Gherkin.ScenarioOutline do
  @moduledoc """
  Represents a Gherkin Scenario Outline section.

  A Scenario Outline is a template that runs multiple times with different data
  from Examples tables. Placeholders in step text use `<name>` syntax and are
  substituted with values from each row of the Examples table.
  """
  defstruct name: "", steps: [], tags: [], examples: [], line: nil

  @type t :: %__MODULE__{
          name: String.t(),
          steps: [Gherkin.Step.t()],
          tags: [String.t()],
          examples: [Gherkin.Examples.t()],
          line: non_neg_integer() | nil
        }
end

defmodule Gherkin.Examples do
  @moduledoc """
  Represents an Examples block within a Scenario Outline.

  Each Examples block contains a table of data used to parameterize the outline.
  The first row contains headers (placeholder names), and subsequent rows contain
  values to substitute. Examples blocks can have optional names and tags.
  """
  defstruct name: "", tags: [], table_header: [], table_body: [], line: nil

  @type t :: %__MODULE__{
          name: String.t(),
          tags: [String.t()],
          table_header: [String.t()],
          table_body: [[String.t()]],
          line: non_neg_integer() | nil
        }
end

defmodule Gherkin.Step do
  @moduledoc """
  Represents a Gherkin step (Given/When/Then/And/But/*).

  A Step is a single action or assertion in a scenario. It consists of:
  - keyword: The step type (Given, When, Then, And, But, or *)
  - text: The step text that matches step definitions
  - docstring: Optional multi-line text block (triple-quoted)
  - datatable: Optional table data (pipe-delimited)
  - line: Line number in the source file
  """
  defstruct keyword: "", text: "", docstring: nil, datatable: nil, line: nil

  @type t :: %__MODULE__{
          keyword: String.t(),
          text: String.t(),
          docstring: String.t() | nil,
          datatable: [[String.t()]] | nil,
          line: non_neg_integer() | nil
        }
end

# Initial parser module scaffold

defmodule Gherkin.Parser do
  @moduledoc """
  Minimal Gherkin 6 parser (Feature, Background, Scenario, Step).

  This module parses Gherkin feature files into Elixir structs, supporting:
  - Feature with name, description, and tags
  - Background with steps
  - Scenarios with steps and tags
  - Steps with keywords, text, docstrings, and datatables

  It implements a subset of the Gherkin language focused on core BDD concepts.
  """

  alias Gherkin.{Background, Examples, Feature, Scenario, ScenarioOutline, Step}

  @doc """
  Parses a Gherkin feature file from a string into structured data.

  This function takes a string containing Gherkin syntax and parses it into a
  structured `Gherkin.Feature` struct with its associated components.

  ## Parameters

  * `gherkin_string` - A string containing Gherkin syntax

  ## Returns

  Returns a `%Gherkin.Feature{}` struct containing:
  * `name` - The feature name
  * `description` - The feature description
  * `tags` - List of feature-level tags
  * `background` - Background steps (if present)
  * `scenarios` - List of scenarios

  ## Examples

      # Parse a string containing Gherkin syntax
      Gherkin.Parser.parse("Feature: Shopping Cart\nScenario: Adding an item")
      # Returns %Gherkin.Feature{} struct with parsed data
  """
  def parse(gherkin_string) do
    lines =
      gherkin_string
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)

    # Keep track of original lines with their line numbers
    all_lines_indexed =
      gherkin_string
      |> String.split("\n")
      |> Enum.with_index()

    with {feature_tags, feature_line, rest} <- extract_tags_and_element(lines, "Feature:"),
         feature_name <- extract_feature_name(feature_line),
         {background, after_bg} <- extract_background(rest),
         scenarios <- parse_scenarios_with_lines(after_bg, all_lines_indexed) do
      %Feature{
        name: feature_name,
        description: "",
        background: background,
        scenarios: scenarios,
        tags: feature_tags
      }
    end
  end

  defp extract_feature_name(feature_line) do
    [_, feature_name] = String.split(feature_line, ":", parts: 2)
    String.trim(feature_name)
  end

  defp extract_background(lines) do
    {bg_lines, rest_with_scenarios} =
      Enum.split_while(lines, fn line ->
        !String.starts_with?(line, "Scenario:") &&
          !String.starts_with?(line, "Scenario Outline:") &&
          !String.starts_with?(line, "@")
      end)

    background = parse_background(bg_lines)
    {background, rest_with_scenarios}
  end

  defp parse_background(lines) do
    if Enum.any?(lines, &String.starts_with?(&1, "Background:")) do
      steps = parse_background_steps(lines)
      %Background{steps: steps}
    else
      nil
    end
  end

  defp parse_background_steps(lines) do
    lines
    |> Enum.drop_while(&(&1 == "" or String.starts_with?(&1, "Background:")))
    |> parse_steps(lines)
  end

  # Parse steps for both background and scenarios
  defp parse_steps(step_lines, all_lines) do
    initial_state = {[], nil, false}

    {steps, _, _} =
      Enum.reduce(step_lines, initial_state, fn line, state ->
        process_step_line(line, state, all_lines)
      end)

    Enum.reverse(steps)
  end

  # Process a single line when parsing steps
  defp process_step_line(line, {steps, current_step, in_docstring} = state, all_lines) do
    cond do
      String.starts_with?(line, ~s(""")) ->
        handle_docstring_marker(steps, current_step, in_docstring)

      in_docstring ->
        handle_docstring_content(line, steps, current_step)

      String.starts_with?(line, "|") ->
        handle_table_row(line, steps, current_step, in_docstring)

      match = Regex.run(~r/^(Given|When|Then|And|But|\*) (.+)$/, line, capture: :all_but_first) ->
        handle_step(match, steps, all_lines)

      true ->
        state
    end
  end

  defp handle_docstring_marker(steps, current_step, in_docstring) do
    if in_docstring do
      {steps, nil, false}
    else
      {steps, current_step, true}
    end
  end

  defp handle_docstring_content(line, steps, current_step) do
    updated_step =
      if is_nil(current_step.docstring) do
        %{current_step | docstring: line}
      else
        %{current_step | docstring: current_step.docstring <> "\n" <> line}
      end

    updated_steps = List.replace_at(steps, 0, updated_step)
    {updated_steps, updated_step, true}
  end

  defp handle_table_row(line, steps, current_step, in_docstring) do
    table_row =
      line
      |> String.split("|", trim: true)
      |> Enum.map(&String.trim/1)

    if current_step do
      updated_step =
        if current_step.datatable do
          %{current_step | datatable: current_step.datatable ++ [table_row]}
        else
          %{current_step | datatable: [table_row]}
        end

      updated_steps = List.replace_at(steps, 0, updated_step)
      {updated_steps, updated_step, in_docstring}
    else
      {steps, current_step, in_docstring}
    end
  end

  defp handle_step([keyword, text], steps, all_lines) do
    line_number = Enum.find_index(all_lines, &(&1 =~ text)) || 0
    new_step = %Step{keyword: keyword, text: text, line: line_number}
    {[new_step | steps], new_step, false}
  end

  # Parse scenarios with line number tracking
  # State tuple: {scenarios, current_scenario, current_tags, steps, current_step, in_docstring, line_num, outline_state}
  # outline_state is nil for regular scenarios, or {examples_list, current_examples, examples_tags} for outlines
  # current_examples is nil or {name, line, header, body}
  defp parse_scenarios_with_lines(lines, all_lines_indexed) do
    initial_state = {[], nil, [], [], nil, false, nil, nil}

    {scenarios, current_scenario, current_tags, steps, _current_step, _in_docstring, _,
     outline_state} =
      Enum.reduce(lines, initial_state, fn line, state ->
        process_line_with_number(line, state, lines, all_lines_indexed)
      end)

    # Add the last scenario/outline if present
    finalize_scenarios_with_line(scenarios, current_scenario, current_tags, steps, outline_state)
  end

  # Extract tags from a line like "@tag1 @tag2 @tag3"
  defp extract_tags(line) do
    line
    |> String.split(~r/\s+/)
    |> Enum.filter(&String.starts_with?(&1, "@"))
    |> Enum.map(&String.trim_leading(&1, "@"))
  end

  # Extract tags from lines before a Feature/Scenario, returns {tags, element_line, rest}
  defp extract_tags_and_element(lines, element_prefix) do
    {tag_lines, rest} = Enum.split_while(lines, &(String.starts_with?(&1, "@") or &1 == ""))

    # Extract tags from tag lines
    tags =
      tag_lines
      |> Enum.filter(&String.starts_with?(&1, "@"))
      |> Enum.flat_map(&extract_tags/1)

    # Find the element line
    {element_line, new_rest} =
      case Enum.split_while(rest, &(!String.starts_with?(&1, element_prefix))) do
        {_, []} -> raise "No #{element_prefix} found after tags"
        {_pre, [element | post]} -> {element, post}
      end

    {tags, element_line, new_rest}
  end

  defp finalize_scenarios_with_line(
         scenarios,
         current_scenario,
         current_tags,
         steps,
         outline_state
       ) do
    if current_scenario do
      {scenario_line, line_num, is_outline} = current_scenario

      scenario_or_outline =
        if is_outline do
          build_outline_with_line(scenario_line, steps, current_tags, line_num, outline_state)
        else
          build_scenario_with_line(scenario_line, steps, current_tags, line_num)
        end

      scenarios ++ [scenario_or_outline]
    else
      scenarios
    end
  end

  defp build_scenario_with_line(scenario_line, steps, tags, line_num) do
    [_, scenario_name] = String.split(scenario_line, ":", parts: 2)
    scenario_name = String.trim(scenario_name)

    %Scenario{
      name: scenario_name,
      steps: Enum.reverse(steps),
      tags: tags,
      line: line_num
    }
  end

  defp build_outline_with_line(outline_line, steps, tags, line_num, outline_state) do
    [_, outline_name] = String.split(outline_line, ":", parts: 2)
    outline_name = String.trim(outline_name)

    # Finalize any in-progress Examples block
    {examples_list, current_examples, _examples_tags} = outline_state
    all_examples = finalize_current_examples(examples_list, current_examples)

    %ScenarioOutline{
      name: outline_name,
      steps: Enum.reverse(steps),
      tags: tags,
      examples: all_examples,
      line: line_num
    }
  end

  defp finalize_current_examples(examples_list, nil), do: examples_list

  defp finalize_current_examples(examples_list, {name, line, tags, header, body}) do
    examples = %Examples{
      name: name,
      tags: tags,
      table_header: header,
      table_body: Enum.reverse(body),
      line: line
    }

    examples_list ++ [examples]
  end

  defp process_line_with_number(line, state, lines, all_lines_indexed) do
    {scenarios, current_scenario, current_tags, steps, current_step, in_docstring, _line_num,
     outline_state} =
      state

    # Check if we're currently collecting Examples table rows
    in_examples_table = in_examples_table?(outline_state)

    cond do
      # Handle tags - could be for scenario, outline, or Examples
      String.starts_with?(line, "@") ->
        handle_tag_with_line(line, state, outline_state)

      # Handle Scenario Outline keyword
      String.starts_with?(line, "Scenario Outline:") ->
        line_num = find_line_number(line, all_lines_indexed)
        handle_scenario_outline_with_line(line, line_num, state)

      # Handle regular Scenario keyword
      String.starts_with?(line, "Scenario:") ->
        line_num = find_line_number(line, all_lines_indexed)
        handle_scenario_with_line(line, line_num, state)

      # Handle Examples keyword (only valid inside a Scenario Outline)
      String.starts_with?(line, "Examples:") ->
        line_num = find_line_number(line, all_lines_indexed)
        handle_examples_with_line(line, line_num, state, outline_state)

      # Handle table rows - could be step datatable or Examples table
      String.starts_with?(line, "|") ->
        if in_examples_table do
          handle_examples_table_row(line, state, outline_state)
        else
          # Process as step datatable
          {new_steps, new_current_step, new_in_docstring} =
            process_step_line(line, {steps, current_step, in_docstring}, lines)

          {scenarios, current_scenario, current_tags, new_steps, new_current_step,
           new_in_docstring, nil, outline_state}
        end

      # For step-related lines (docstrings and steps) - but not inside Examples table
      String.starts_with?(line, ~s(""")) or in_docstring or
          Regex.match?(~r/^(Given|When|Then|And|But|\*) /, line) ->
        # Process the step-related line
        {new_steps, new_current_step, new_in_docstring} =
          process_step_line(line, {steps, current_step, in_docstring}, lines)

        {scenarios, current_scenario, current_tags, new_steps, new_current_step, new_in_docstring,
         nil, outline_state}

      true ->
        # Ignore other lines
        state
    end
  end

  defp in_examples_table?(nil), do: false
  defp in_examples_table?({_examples_list, current_examples, _tags}), do: current_examples != nil

  defp find_line_number(line, all_lines_indexed) do
    trimmed_line = String.trim(line)

    case Enum.find(all_lines_indexed, fn {orig_line, _idx} ->
           String.trim(orig_line) == trimmed_line
         end) do
      {_, idx} -> idx
      nil -> 0
    end
  end

  defp handle_tag_with_line(
         line,
         {scenarios, current_scenario, current_tags, steps, _current_step, _in_docstring,
          _line_num, outline_state},
         outline_state
       ) do
    new_tags = extract_tags(line)

    # If we're in an outline and have started Examples, tags go to Examples
    case outline_state do
      {examples_list, current_examples, _old_examples_tags} when current_examples != nil ->
        # Finalize current Examples block, start accumulating tags for next one
        new_examples_list = finalize_current_examples(examples_list, current_examples)
        new_outline_state = {new_examples_list, nil, new_tags}
        {scenarios, current_scenario, current_tags, steps, nil, false, nil, new_outline_state}

      {examples_list, nil, _old_examples_tags} ->
        # In outline but no current Examples - these tags are for Examples
        new_outline_state = {examples_list, nil, new_tags}
        {scenarios, current_scenario, current_tags, steps, nil, false, nil, new_outline_state}

      nil ->
        # Not in outline - handle as before
        if current_scenario do
          {scenario_line, line_num, is_outline} = current_scenario

          if is_outline do
            # Finalize the outline
            outline =
              build_outline_with_line(scenario_line, steps, current_tags, line_num, outline_state)

            {scenarios ++ [outline], nil, new_tags, [], nil, false, nil, nil}
          else
            scenario = build_scenario_with_line(scenario_line, steps, current_tags, line_num)
            {scenarios ++ [scenario], nil, new_tags, [], nil, false, nil, nil}
          end
        else
          {scenarios, current_scenario, new_tags, steps, nil, false, nil, nil}
        end
    end
  end

  defp handle_scenario_with_line(
         line,
         line_num,
         {scenarios, current_scenario, current_tags, steps, _current_step, _in_docstring, _,
          outline_state}
       ) do
    if current_scenario do
      {scenario_line, old_line_num, is_outline} = current_scenario

      scenario_or_outline =
        if is_outline do
          build_outline_with_line(scenario_line, steps, current_tags, old_line_num, outline_state)
        else
          build_scenario_with_line(scenario_line, steps, current_tags, old_line_num)
        end

      {scenarios ++ [scenario_or_outline], {line, line_num, false}, [], [], nil, false, nil, nil}
    else
      {scenarios, {line, line_num, false}, current_tags, [], nil, false, nil, nil}
    end
  end

  defp handle_scenario_outline_with_line(
         line,
         line_num,
         {scenarios, current_scenario, current_tags, steps, _current_step, _in_docstring, _,
          outline_state}
       ) do
    if current_scenario do
      {scenario_line, old_line_num, is_outline} = current_scenario

      scenario_or_outline =
        if is_outline do
          build_outline_with_line(scenario_line, steps, current_tags, old_line_num, outline_state)
        else
          build_scenario_with_line(scenario_line, steps, current_tags, old_line_num)
        end

      # Start new outline with fresh outline_state
      {scenarios ++ [scenario_or_outline], {line, line_num, true}, [], [], nil, false, nil,
       {[], nil, []}}
    else
      # Start new outline
      {scenarios, {line, line_num, true}, current_tags, [], nil, false, nil, {[], nil, []}}
    end
  end

  defp handle_examples_with_line(
         line,
         line_num,
         {scenarios, current_scenario, current_tags, steps, _current_step, _in_docstring, _,
          _old_outline_state},
         outline_state
       ) do
    # Extract Examples name from line like "Examples: positive numbers" or just "Examples:"
    examples_name =
      case String.split(line, ":", parts: 2) do
        [_, name] -> String.trim(name)
        _ -> ""
      end

    {examples_list, current_examples, examples_tags} = outline_state || {[], nil, []}

    # Finalize any previous Examples block
    new_examples_list = finalize_current_examples(examples_list, current_examples)

    # Start new Examples block (header and body will be filled by table rows)
    new_current_examples = {examples_name, line_num, examples_tags, [], []}
    new_outline_state = {new_examples_list, new_current_examples, []}

    {scenarios, current_scenario, current_tags, steps, nil, false, nil, new_outline_state}
  end

  defp handle_examples_table_row(
         line,
         {scenarios, current_scenario, current_tags, steps, _current_step, _in_docstring, _,
          _old_outline_state},
         outline_state
       ) do
    table_row =
      line
      |> String.split("|", trim: true)
      |> Enum.map(&String.trim/1)

    {examples_list, current_examples, examples_tags} = outline_state
    {name, ex_line, ex_tags, header, body} = current_examples

    # First row is header, subsequent rows are body
    {new_header, new_body} =
      if header == [] do
        {table_row, body}
      else
        {header, [table_row | body]}
      end

    new_current_examples = {name, ex_line, ex_tags, new_header, new_body}
    new_outline_state = {examples_list, new_current_examples, examples_tags}

    {scenarios, current_scenario, current_tags, steps, nil, false, nil, new_outline_state}
  end
end
