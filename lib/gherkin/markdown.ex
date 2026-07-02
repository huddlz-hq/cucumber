defmodule Gherkin.Markdown do
  @moduledoc """
  Parser for Markdown feature files — "Markdown with Gherkin" (MDG).

  MDG embeds Gherkin in ordinary Markdown (`.feature.md` files):

    * Section headers are ATX headings whose text is a Gherkin keyword —
      `# Feature: Name`, `## Rule: Name`, `### Scenario: Name`,
      `#### Examples: Name`. The heading level is decorative; nesting comes
      from the keywords alone.
    * Steps are bullet-list items: `* Given a step` (`-` and `+` bullets
      also work). The `*` step keyword is not available — a bare `* text`
      bullet is ordinary prose.
    * Docstrings are fenced code blocks (three or more backticks) under a
      step. The info string becomes the media type, the fence's indentation
      is stripped from the content, and the closing fence must repeat the
      opening backticks exactly, so a longer fence can wrap a shorter one.
    * Data tables and Examples tables are Markdown tables indented two to
      five spaces. GFM separator rows (`| --- |`) are skipped. Tables
      without the indent are ordinary prose and ignored.
    * Tags are inline code spans on their own line before the section they
      tag: `` `@wip` `@slow` ``. Bare `@wip` text is prose, not a tag.
    * Everything else — prose, unindented tables, headings without a
      Gherkin keyword — is ignored. Section descriptions are therefore
      always empty, and there are no comment lines (`#` starts a heading,
      so `feature.comments` is always empty).

  Mirroring the reference tokenizer (`@cucumber/gherkin`'s
  `GherkinInMarkdownTokenMatcher`), the first line of the file becomes the
  feature line even when it is not a `# Feature:` heading — the whole
  trimmed line is taken as the feature name — and any later `# Feature:`
  heading is ignored.

  Two deliberate divergences from the reference tokenizer, both lenient:

    * A fenced code block with no step to attach to (in prose) is skipped
      entirely, so code samples containing `* Given ...` lines don't parse
      as steps.
    * The reference captures prose that follows a GFM separator row as a
      section description — an emergent quirk of its error-tolerant token
      matching, not MDG behavior. This parser captures no descriptions.

  Produces the same `Gherkin.Feature` structs as `Gherkin.NimbleParser`,
  with 0-based line numbers referring to the original Markdown source, so
  everything downstream — compiler, runtime, Cucumber Messages — behaves
  exactly as it does for `.feature` files.
  """

  alias Gherkin.{Background, Examples, Feature, Rule, Scenario, ScenarioOutline, Step}

  @header_regex ~r/^\#{1,6}\s(Feature|Rule|Background|Scenario Outline|Scenario Template|Scenario|Example|Examples|Scenarios):(.*)$/
  @step_regex ~r/^\s*[*+-]\s*(Given|When|Then|And|But) (.*)$/
  @table_row_regex ~r/^\s{2,5}\|/
  @tag_regex ~r/`@([^`]+)`/
  @fence_regex ~r/^(```+)(.*)$/
  @separator_cell_regex ~r/^:?-+:?$/

  @doc """
  Parses a Markdown feature file string into a `Gherkin.Feature` struct.

  Raises `Gherkin.ParseError` when the Gherkin structure is invalid (a step
  outside a scenario, an Examples table outside a Scenario Outline, an
  unclosed code fence, and similar).
  """
  @spec parse(String.t()) :: Feature.t()
  def parse(source) do
    state = %{
      feature: nil,
      background: nil,
      scenarios: [],
      rules: [],
      rule: nil,
      section: nil,
      pending_tags: [],
      fence: nil
    }

    source
    |> String.split(~r/\r?\n/)
    |> Enum.with_index()
    |> Enum.reduce(state, &handle_line/2)
    |> finish()
  end

  # --- Line dispatch ---------------------------------------------------

  defp handle_line({raw, _index}, %{fence: fence} = state) when fence != nil do
    if String.trim(raw) == fence.delimiter do
      close_fence(state)
    else
      %{state | fence: %{fence | content: [raw | fence.content]}}
    end
  end

  defp handle_line({raw, index}, state) do
    tags = Regex.scan(@tag_regex, raw, capture: :all_but_first)

    cond do
      tags != [] ->
        tagged = for [name] <- tags, do: {name, index}
        %{state | pending_tags: state.pending_tags ++ tagged}

      state.feature == nil ->
        start_feature(raw, index, state)

      match = Regex.run(@header_regex, raw, capture: :all_but_first) ->
        [keyword, name] = match
        handle_header(keyword, String.trim(name), index, state)

      match = Regex.run(@step_regex, raw, capture: :all_but_first) ->
        [keyword, text] = match
        handle_step(keyword, String.trim(text), index, raw, state)

      match = Regex.run(@fence_regex, String.trim_leading(raw), capture: :all_but_first) ->
        [delimiter, info] = match
        open_fence(delimiter, info, raw, index, state)

      Regex.match?(@table_row_regex, raw) ->
        handle_table_row(raw, index, state)

      true ->
        state
    end
  end

  # --- Feature line ----------------------------------------------------

  # The first line that isn't a tag line becomes the feature: a proper
  # `# Feature:` heading when it is one, otherwise the whole trimmed line
  # is the feature name (the reference tokenizer's fallback). GFM separator
  # rows are the one exception — they are comments and skipped.
  defp start_feature(raw, index, state) do
    cond do
      separator_row?(raw) ->
        state

      match = Regex.run(@header_regex, raw, capture: :all_but_first) ->
        ["Feature", name] = match
        set_feature(String.trim(name), index, state)

      true ->
        set_feature(String.trim(raw), index, state)
    end
  end

  defp set_feature(name, line, state) do
    {{tags, tag_lines}, state} = take_tags(state)

    %{state | feature: %{name: name, line: line, tags: tags, tag_lines: tag_lines}}
  end

  # --- Section headers -------------------------------------------------

  # A later `# Feature:` heading is ignored, like the reference tokenizer
  # (its feature line matches only once); pending tags stay pending.
  defp handle_header("Feature", _name, _line, state), do: state

  defp handle_header("Rule", name, line, state) do
    state = state |> close_section() |> close_rule()
    {{tags, tag_lines}, state} = take_tags(state)

    rule = %{
      name: name,
      line: line,
      tags: tags,
      tag_lines: tag_lines,
      background: nil,
      scenarios: []
    }

    %{state | rule: rule}
  end

  defp handle_header("Background", name, line, state) do
    state = close_section(state)
    container_scenarios = if state.rule, do: state.rule.scenarios, else: state.scenarios
    container_background = if state.rule, do: state.rule.background, else: state.background

    if container_scenarios != [] or container_background != nil do
      parse_error("a single Background before the first Scenario", line)
    end

    %{state | section: {:background, %{name: name, line: line, steps: []}}}
  end

  defp handle_header(keyword, name, line, state) when keyword in ["Scenario", "Example"] do
    state = close_section(state)
    {{tags, tag_lines}, state} = take_tags(state)

    section =
      {:scenario,
       %{keyword: keyword, name: name, line: line, tags: tags, tag_lines: tag_lines, steps: []}}

    %{state | section: section}
  end

  defp handle_header(keyword, name, line, state)
       when keyword in ["Scenario Outline", "Scenario Template"] do
    state = close_section(state)
    {{tags, tag_lines}, state} = take_tags(state)

    outline = %{
      keyword: keyword,
      name: name,
      line: line,
      tags: tags,
      tag_lines: tag_lines,
      steps: [],
      examples: [],
      current_examples: nil
    }

    %{state | section: {:outline, outline}}
  end

  defp handle_header(keyword, name, line, state) when keyword in ["Examples", "Scenarios"] do
    case state.section do
      {:outline, outline} ->
        outline = push_examples(outline)
        {{tags, tag_lines}, state} = take_tags(state)

        examples = %{
          keyword: keyword,
          name: name,
          line: line,
          tags: tags,
          tag_lines: tag_lines,
          header: nil,
          header_line: nil,
          body: [],
          body_lines: []
        }

        %{state | section: {:outline, %{outline | current_examples: examples}}}

      _other ->
        parse_error("a Scenario Outline before an Examples table", line)
    end
  end

  # --- Steps -----------------------------------------------------------

  defp handle_step(keyword, text, line, raw, state) do
    step = %Step{keyword: keyword, text: text, line: line}

    case state.section do
      {:background, background} ->
        %{state | section: {:background, %{background | steps: [step | background.steps]}}}

      {:scenario, scenario} ->
        %{state | section: {:scenario, %{scenario | steps: [step | scenario.steps]}}}

      {:outline, %{current_examples: nil} = outline} ->
        %{state | section: {:outline, %{outline | steps: [step | outline.steps]}}}

      {:outline, _outline} ->
        parse_error("steps to come before the Examples tables", line, raw)

      nil ->
        parse_error("a Scenario or Background heading before the first step", line, raw)
    end
  end

  # --- Tables ----------------------------------------------------------

  defp handle_table_row(raw, line, state) do
    if separator_row?(raw) do
      state
    else
      attach_table_row(table_cells(raw), raw, line, state)
    end
  end

  defp attach_table_row(cells, raw, line, state) do
    case state.section do
      {:outline, %{current_examples: %{header: nil} = examples} = outline} ->
        examples = %{examples | header: cells, header_line: line}
        %{state | section: {:outline, %{outline | current_examples: examples}}}

      {:outline, %{current_examples: %{} = examples} = outline} ->
        examples = %{
          examples
          | body: [cells | examples.body],
            body_lines: [line | examples.body_lines]
        }

        %{state | section: {:outline, %{outline | current_examples: examples}}}

      section ->
        case current_step(section) do
          nil -> parse_error("a step or an Examples heading before a table row", line, raw)
          step -> update_current_step(state, add_table_row(step, cells, line))
        end
    end
  end

  defp add_table_row(step, cells, line) do
    %{
      step
      | datatable: (step.datatable || []) ++ [cells],
        datatable_lines: (step.datatable_lines || []) ++ [line]
    }
  end

  # Cells follow the `.feature` parser's conventions: split on `|`,
  # trimmed, empties dropped.
  defp table_cells(raw) do
    raw
    |> String.trim()
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # A GFM separator row: any cell of dashes with optional alignment colons
  # (`---`, `:--`, `--:`), matching the reference tokenizer.
  defp separator_row?(raw) do
    trimmed = String.trim(raw)

    String.starts_with?(trimmed, "|") and
      Enum.any?(table_cells(raw), &Regex.match?(@separator_cell_regex, &1))
  end

  # --- Docstrings (fenced code blocks) ---------------------------------

  defp open_fence(delimiter, info, raw, line, state) do
    owner =
      case current_step(state.section) do
        nil -> :prose
        %Step{docstring: nil} -> :step
        %Step{} -> parse_error("a single docstring per step", line, raw)
      end

    media_type =
      case String.trim(info) do
        "" -> nil
        media -> media
      end

    fence = %{
      delimiter: delimiter,
      indent: leading_whitespace(raw),
      line: line,
      media_type: media_type,
      content: [],
      owner: owner
    }

    %{state | fence: fence}
  end

  defp close_fence(%{fence: %{owner: :prose}} = state), do: %{state | fence: nil}

  defp close_fence(%{fence: fence} = state) do
    content =
      fence.content
      |> Enum.reverse()
      |> Enum.map_join("\n", &dedent(&1, fence.indent))

    updated = %{
      current_step(state.section)
      | docstring: content,
        docstring_media_type: fence.media_type,
        docstring_line: fence.line,
        docstring_delimiter: fence.delimiter
    }

    %{update_current_step(state, updated) | fence: nil}
  end

  # Content is dedented by the opening fence's indentation; a line indented
  # less than the fence loses only its own leading whitespace (mirroring
  # the reference tokenizer).
  defp dedent(line, indent) do
    if leading_whitespace(line) >= indent do
      String.slice(line, indent..-1//1)
    else
      String.trim_leading(line)
    end
  end

  defp leading_whitespace(line) do
    line
    |> String.graphemes()
    |> Enum.take_while(&(&1 in [" ", "\t"]))
    |> length()
  end

  # --- Step bookkeeping ------------------------------------------------

  # The most recent step of the active section, if table rows and fences
  # can still attach to it (an open Examples block claims them instead).
  defp current_step({:background, %{steps: [step | _]}}), do: step
  defp current_step({:scenario, %{steps: [step | _]}}), do: step
  defp current_step({:outline, %{current_examples: nil, steps: [step | _]}}), do: step
  defp current_step(_section), do: nil

  defp update_current_step(%{section: {kind, acc}} = state, step) do
    %{state | section: {kind, %{acc | steps: [step | tl(acc.steps)]}}}
  end

  # --- Closing sections ------------------------------------------------

  defp close_section(%{section: nil} = state), do: state

  defp close_section(%{section: {:background, acc}} = state) do
    background = %Background{name: acc.name, line: acc.line, steps: Enum.reverse(acc.steps)}

    case state.rule do
      nil -> %{state | background: background, section: nil}
      rule -> %{state | rule: %{rule | background: background}, section: nil}
    end
  end

  defp close_section(%{section: {:scenario, acc}} = state) do
    scenario = %Scenario{
      keyword: acc.keyword,
      name: acc.name,
      line: acc.line,
      tags: acc.tags,
      tag_lines: acc.tag_lines,
      steps: Enum.reverse(acc.steps)
    }

    add_scenario(%{state | section: nil}, scenario)
  end

  defp close_section(%{section: {:outline, acc}} = state) do
    acc = push_examples(acc)

    outline = %ScenarioOutline{
      keyword: acc.keyword,
      name: acc.name,
      line: acc.line,
      tags: acc.tags,
      tag_lines: acc.tag_lines,
      steps: Enum.reverse(acc.steps),
      examples: Enum.reverse(acc.examples)
    }

    add_scenario(%{state | section: nil}, outline)
  end

  defp add_scenario(%{rule: nil} = state, scenario) do
    %{state | scenarios: [scenario | state.scenarios]}
  end

  defp add_scenario(%{rule: rule} = state, scenario) do
    %{state | rule: %{rule | scenarios: [scenario | rule.scenarios]}}
  end

  defp push_examples(%{current_examples: nil} = outline), do: outline

  defp push_examples(%{current_examples: acc} = outline) do
    examples = %Examples{
      keyword: acc.keyword,
      name: acc.name,
      line: acc.line,
      tags: acc.tags,
      tag_lines: acc.tag_lines,
      table_header: acc.header || [],
      table_header_line: acc.header_line,
      table_body: Enum.reverse(acc.body),
      table_body_lines: Enum.reverse(acc.body_lines)
    }

    %{outline | examples: [examples | outline.examples], current_examples: nil}
  end

  defp close_rule(%{rule: nil} = state), do: state

  defp close_rule(%{rule: acc} = state) do
    rule = %Rule{
      name: acc.name,
      line: acc.line,
      tags: acc.tags,
      tag_lines: acc.tag_lines,
      background: acc.background,
      scenarios: Enum.reverse(acc.scenarios)
    }

    %{state | rules: [rule | state.rules], rule: nil}
  end

  # --- Finish ----------------------------------------------------------

  defp finish(%{fence: %{} = fence}) do
    parse_error("a closing #{fence.delimiter} fence before the end of the file", fence.line)
  end

  defp finish(state) do
    state = state |> close_section() |> close_rule()
    feature = state.feature || %{name: "", line: 0, tags: [], tag_lines: []}

    %Feature{
      name: feature.name,
      line: feature.line,
      tags: feature.tags,
      tag_lines: feature.tag_lines,
      background: state.background,
      scenarios: Enum.reverse(state.scenarios),
      rules: Enum.reverse(state.rules)
    }
  end

  defp take_tags(state) do
    {Enum.unzip(state.pending_tags), %{state | pending_tags: []}}
  end

  # ParseError lines are 1-based, matching the `.feature` parser's
  # NimbleParsec-reported positions.
  @spec parse_error(String.t(), non_neg_integer(), String.t() | nil) :: no_return()
  defp parse_error(expected, line, raw \\ nil) do
    raise Gherkin.ParseError,
      message: expected,
      line: line + 1,
      column: 1,
      rest: raw && String.slice(String.trim(raw), 0, 50)
  end
end
