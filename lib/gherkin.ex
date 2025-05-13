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
    scenarios: [Gherkin.Scenario.t()],
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
  It consists of a name, a list of steps, and optional tags for filtering.
  """
  defstruct name: "", steps: [], tags: []
  
  @type t :: %__MODULE__{
    name: String.t(),
    steps: [Gherkin.Step.t()],
    tags: [String.t()]
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

  alias Gherkin.{Feature, Background, Scenario, Step}

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
    lines = String.split(gherkin_string, "\n", trim: true)
    lines = Enum.map(lines, &String.trim/1)

    # Extract feature tags and name
    {feature_tags, feature_line, rest} = extract_tags_and_element(lines, "Feature:")
    [_, feature_name] = String.split(feature_line, ":", parts: 2)
    feature_name = String.trim(feature_name)

    # Find Background (optional)
    {background, after_bg} =
      case Enum.split_while(rest, fn line ->
             !String.starts_with?(line, "Scenario:") && !String.starts_with?(line, "@")
           end) do
        {bg_lines, rest_with_scenarios} ->
          has_background = Enum.any?(bg_lines, &String.starts_with?(&1, "Background:"))

          if has_background do
            # Extract background details with docstring and datatable support
            {bg_steps, _, _, _} =
              bg_lines
              |> Enum.drop_while(&(&1 == "" or String.starts_with?(&1, "Background:")))
              |> Enum.reduce({[], nil, false, nil}, fn line,
                                                       {steps, current_step, in_docstring, _} ->
                cond do
                  # Docstring start/end marker
                  String.starts_with?(line, ~s(""")) ->
                    if in_docstring do
                      # End of docstring
                      {steps, nil, false, nil}
                    else
                      # Start of docstring
                      {steps, current_step, true, nil}
                    end

                  # Inside a docstring, collect content
                  in_docstring ->
                    # Append this line to the docstring of the current step
                    # Initialize the docstring if nil, otherwise append with newline
                    updated_step =
                      if is_nil(current_step.docstring) do
                        %{current_step | docstring: line}
                      else
                        %{current_step | docstring: current_step.docstring <> "\n" <> line}
                      end

                    # Replace the current step in the steps list
                    updated_steps = List.replace_at(steps, 0, updated_step)
                    {updated_steps, updated_step, in_docstring, nil}

                  # Data table row
                  String.starts_with?(line, "|") ->
                    table_row =
                      line
                      |> String.split("|", trim: true)
                      |> Enum.map(&String.trim/1)

                    if current_step do
                      # If we already have a step, add this row to its datatable
                      updated_step =
                        if current_step.datatable do
                          %{current_step | datatable: current_step.datatable ++ [table_row]}
                        else
                          %{current_step | datatable: [table_row]}
                        end

                      # Replace the current step in the steps list
                      updated_steps = List.replace_at(steps, 0, updated_step)
                      {updated_steps, updated_step, in_docstring, nil}
                    else
                      # This shouldn't happen (table row without a step)
                      {steps, current_step, in_docstring, nil}
                    end

                  # Step line
                  Regex.match?(~r/^(Given|When|Then|And|But|\*) /, line) ->
                    [keyword, text] =
                      Regex.run(~r/^(Given|When|Then|And|But|\*) (.+)$/, line,
                        capture: :all_but_first
                      )

                    # Track the original line number by using the index in the list
                    line_number = Enum.find_index(bg_lines, &(&1 =~ text)) || 0
                    new_step = %Step{keyword: keyword, text: text, line: line_number}
                    {[new_step | steps], new_step, false, nil}

                  # Ignore other lines
                  true ->
                    {steps, current_step, in_docstring, nil}
                end
              end)

            {%Background{steps: Enum.reverse(bg_steps)}, rest_with_scenarios}
          else
            {nil, rest_with_scenarios}
          end

        _ ->
          {nil, rest}
      end

    # Parse all scenarios with their tags and steps
    scenarios =
      parse_scenarios(after_bg)

    %Feature{
      name: feature_name,
      description: "",
      background: background,
      scenarios: scenarios,
      tags: feature_tags
    }
  end

  # Helper function to parse scenarios with their tags
  defp parse_scenarios(lines) do
    # Keep track of state while parsing
    # current_step tracks the current step being processed for docstring/datatable attachment
    {scenarios, current_scenario, current_tags, steps, _current_step, _in_docstring} =
      Enum.reduce(lines, {[], nil, [], [], nil, false}, fn line,
                                                           {scenarios, current_scenario,
                                                            current_tags, steps, current_step,
                                                            in_docstring} ->
        cond do
          # Docstring start/end marker
          String.starts_with?(line, ~s(""")) ->
            if in_docstring do
              # End of docstring - attach the collected docstring to the current step
              {scenarios, current_scenario, current_tags, steps, nil, false}
            else
              # Start of docstring - begin collecting
              {scenarios, current_scenario, current_tags, steps, current_step, true}
            end

          # Inside a docstring, collect content
          in_docstring ->
            # Append this line to the docstring of the current step
            # Initialize the docstring if nil, otherwise append with newline
            updated_step =
              if is_nil(current_step.docstring) do
                %{current_step | docstring: line}
              else
                %{current_step | docstring: current_step.docstring <> "\n" <> line}
              end

            # Replace the current step in the steps list
            updated_steps = List.replace_at(steps, 0, updated_step)
            {scenarios, current_scenario, current_tags, updated_steps, updated_step, in_docstring}

          # Data table row
          String.starts_with?(line, "|") ->
            table_row =
              line
              |> String.split("|", trim: true)
              |> Enum.map(&String.trim/1)

            if current_step do
              # If we already have a step, add this row to its datatable
              updated_step =
                if current_step.datatable do
                  %{current_step | datatable: current_step.datatable ++ [table_row]}
                else
                  %{current_step | datatable: [table_row]}
                end

              # Replace the current step in the steps list
              updated_steps = List.replace_at(steps, 0, updated_step)

              {scenarios, current_scenario, current_tags, updated_steps, updated_step,
               in_docstring}
            else
              # This should not happen (table row without a step), but handle gracefully
              {scenarios, current_scenario, current_tags, steps, current_step, in_docstring}
            end

          # Tag line
          String.starts_with?(line, "@") ->
            if current_scenario do
              # Save previous scenario before starting a new one with tags
              [_, scenario_name] = String.split(current_scenario, ":", parts: 2)
              scenario_name = String.trim(scenario_name)

              scenario = %Scenario{
                name: scenario_name,
                steps: Enum.reverse(steps),
                tags: current_tags
              }

              {scenarios ++ [scenario], nil, extract_tags(line), [], nil, false}
            else
              # Tags before first scenario
              {scenarios, current_scenario, extract_tags(line), steps, current_step, false}
            end

          # Scenario line
          String.starts_with?(line, "Scenario:") ->
            if current_scenario do
              # Save previous scenario before starting a new one
              [_, scenario_name] = String.split(current_scenario, ":", parts: 2)
              scenario_name = String.trim(scenario_name)

              scenario = %Scenario{
                name: scenario_name,
                steps: Enum.reverse(steps),
                tags: current_tags
              }

              {scenarios ++ [scenario], line, [], [], nil, false}
            else
              # First scenario or scenario after tags
              {scenarios, line, current_tags, [], nil, false}
            end

          # Step line
          Regex.match?(~r/^(Given|When|Then|And|But|\*) /, line) ->
            [keyword, text] =
              Regex.run(~r/^(Given|When|Then|And|But|\*) (.+)$/, line, capture: :all_but_first)

            # Track the line number based on position in the original lines array
            line_number = Enum.find_index(lines, &(&1 =~ text)) || 0
            new_step = %Step{keyword: keyword, text: text, line: line_number}
            {scenarios, current_scenario, current_tags, [new_step | steps], new_step, false}

          # Ignore other lines
          true ->
            {scenarios, current_scenario, current_tags, steps, current_step, in_docstring}
        end
      end)

    # Add the last scenario if present
    if current_scenario do
      [_, scenario_name] = String.split(current_scenario, ":", parts: 2)
      scenario_name = String.trim(scenario_name)

      scenario = %Scenario{
        name: scenario_name,
        steps: Enum.reverse(steps),
        tags: current_tags
      }

      scenarios ++ [scenario]
    else
      scenarios
    end
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
end
