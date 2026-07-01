defmodule Gherkin.Pickle do
  @moduledoc """
  A pickle: one concrete, runnable scenario compiled from a feature's AST.

  Pickles are the unit of execution in Cucumber — plain scenarios compile
  to one pickle each, scenario outlines to one pickle per examples row
  (with placeholders substituted), and scenarios inside rules inherit the
  rule's background steps and tags. This mirrors the [Cucumber Messages
  `pickle`](https://github.com/cucumber/messages) shape while also
  carrying the provenance the test compiler needs (original names, rule
  and examples-row origin, tag precedence order).

  Fields mirroring the message:

    * `id` - deterministic sequential id, unique within a compilation
    * `uri` - the feature file path
    * `name` - scenario name with outline placeholders substituted
    * `language` - always `"en"` (the parser supports English keywords)
    * `line` - source line of the scenario (or examples row for outlines)
    * `ast_node_ids` - the AST ids this pickle derives from: `[scenario_id]`,
      or `[outline_id, row_id]` for an outline row
    * `tags` - all tags in effect (feature, rule, outline, examples,
      scenario), as `%{name: "tag", ast_node_id: id}` maps
    * `steps` - `Gherkin.PickleStep` structs, background steps first

  Provenance for test generation (not part of the message):

    * `scenario_name`/`scenario_line` - the defining scenario or outline,
      unsubstituted (test names and failure output use these)
    * `rule_name` - the enclosing rule's name, or `nil`
    * `examples_name`/`row_index` - the examples block and 1-based row
      for outline pickles, or `nil`
    * `own_tags` - the scenario's own tags merged with inherited rule /
      outline / examples tags, most specific first (retry-tag precedence)
  """

  defstruct id: nil,
            uri: nil,
            name: "",
            language: "en",
            line: nil,
            ast_node_ids: [],
            tags: [],
            steps: [],
            scenario_name: "",
            scenario_line: nil,
            rule_name: nil,
            examples_name: nil,
            row_index: nil,
            own_tags: []

  @type t :: %__MODULE__{
          id: String.t(),
          uri: String.t() | nil,
          name: String.t(),
          language: String.t(),
          line: non_neg_integer() | nil,
          ast_node_ids: [String.t()],
          tags: [%{name: String.t(), ast_node_id: String.t()}],
          steps: [Gherkin.PickleStep.t()],
          scenario_name: String.t(),
          scenario_line: non_neg_integer() | nil,
          rule_name: String.t() | nil,
          examples_name: String.t() | nil,
          row_index: pos_integer() | nil,
          own_tags: [String.t()]
        }
end

defmodule Gherkin.PickleStep do
  @moduledoc """
  One step of a `Gherkin.Pickle`.

  Mirrors the Cucumber Messages `pickleStep`: `id`, substituted `text`,
  resolved `type` (`:context`/`:action`/`:outcome`/`:unknown` — And/But
  inherit the preceding step's type), and the `ast_node_ids` linking back
  to the gherkinDocument (`[step_id]`, plus the examples-row id for
  outline pickles).

  `step` carries the underlying `Gherkin.Step` (with outline placeholders
  substituted in text, docstring, and datatable) for the runtime, and
  `from_background` marks steps inherited from the feature background —
  the runner reports those separately.
  """

  defstruct id: nil,
            text: "",
            type: :unknown,
            ast_node_ids: [],
            step: nil,
            from_background: false

  @type t :: %__MODULE__{
          id: String.t(),
          text: String.t(),
          type: :context | :action | :outcome | :unknown,
          ast_node_ids: [String.t()],
          step: Gherkin.Step.t(),
          from_background: boolean()
        }
end

defmodule Gherkin.Pickles do
  @moduledoc """
  Compiles a parsed `Gherkin.Feature` into its Cucumber Messages
  `gherkinDocument` node and the list of `Gherkin.Pickle`s to execute.

  This module is the single expansion authority: scenario outlines expand
  to one pickle per examples row (placeholders substituted in step text,
  docstrings, datatables, and the pickle name), and scenarios inside
  rules inherit the rule's background steps and tags. The test compiler
  generates one test per pickle; the messages layer (#28) serializes the
  document and pickles.

  Every AST node the messages format identifies (background, scenario,
  rule, step, tag, examples, table row) receives a deterministic
  sequential string id, assigned in document order; pickles and pickle
  steps continue the same sequence. Ids are unique within one `compile/2`
  call — callers emitting several documents thread `next_id` through.

  The parser tracks lines but not columns, so locations carry only
  `line`. Table rows and docstrings carry their real source lines as
  recorded by the parser (with an owner-derived fallback for hand-built
  ASTs); tags aren't recorded individually and carry the owning section
  header's line.
  """

  alias Gherkin.{Pickle, PickleStep}

  defmodule Compilation do
    @moduledoc "Result of `Gherkin.Pickles.compile/2`."
    defstruct document: %{}, pickles: [], next_id: 0

    @type t :: %__MODULE__{
            document: map(),
            pickles: [Gherkin.Pickle.t()],
            next_id: non_neg_integer()
          }
  end

  @doc """
  Compiles a feature into its gherkinDocument feature node and pickles.

  `feature` is a `Gherkin.Feature` (or the map form discovery produces,
  carrying `:file`). Ids start at `start_id`; the returned `next_id`
  allows threading a run-wide sequence across documents.
  """
  @spec compile(map(), non_neg_integer()) :: Compilation.t()
  def compile(feature, start_id \\ 0) do
    uri = Map.get(feature, :file)

    {feature_tags, ids} = build_tags(feature.tags, Map.get(feature, :line), start_id)

    {background_children, background_source, ids} =
      build_background_child(feature.background, ids)

    {scenario_children, scenario_sources, ids} =
      build_scenario_definitions(feature.scenarios, ids)

    {rule_children, rule_sources, ids} =
      build_rules(Map.get(feature, :rules, []), ids)

    document = %{
      location: location(Map.get(feature, :line)),
      language: "en",
      keyword: "Feature",
      name: feature.name,
      description: feature.description,
      tags: Enum.map(feature_tags, & &1.tag),
      children: background_children ++ scenario_children ++ rule_children
    }

    sources =
      Enum.map(scenario_sources, &Map.put(&1, :rule, nil)) ++
        Enum.flat_map(rule_sources, fn {rule, sources} ->
          Enum.map(sources, &Map.put(&1, :rule, rule))
        end)

    {pickles, next_id} =
      build_pickles(sources, background_source, feature_tags, uri, ids)

    %Compilation{document: document, pickles: pickles, next_id: next_id}
  end

  # ============================================================
  # Document: id-annotated gherkinDocument nodes
  # ============================================================

  @doc false
  # A message location from a parser-convention line. Locations carry only
  # :line — the parser doesn't track columns. Stored lines are 0-based
  # (parser convention); messages are 1-based. Shared with
  # Cucumber.Messages so the two envelope paths can't drift.
  @spec location(non_neg_integer() | nil) :: %{line: pos_integer()}
  def location(nil), do: %{line: 1}
  def location(line), do: %{line: line + 1}

  defp next(ids), do: {Integer.to_string(ids), ids + 1}

  # Tags get ids (pickle tags reference them). Their own lines aren't
  # tracked, so they carry the owning section header's location.
  defp build_tags(tags, owner_line, ids) do
    {entries, ids} =
      Enum.map_reduce(tags, ids, fn tag, ids ->
        {id, ids} = next(ids)

        entry = %{
          name: tag,
          id: id,
          tag: %{location: location(owner_line), name: "@" <> tag, id: id}
        }

        {entry, ids}
      end)

    {entries, ids}
  end

  defp build_background_child(nil, ids), do: {[], nil, ids}

  defp build_background_child(background, ids) do
    {step_entries, ids} = build_steps(background.steps, ids)
    {id, ids} = next(ids)

    child = %{
      background: %{
        id: id,
        location: location(background.line),
        keyword: "Background",
        name: background.name,
        description: background.description,
        steps: Enum.map(step_entries, & &1.node)
      }
    }

    {[child], %{step_entries: step_entries}, ids}
  end

  defp build_scenario_definitions(definitions, ids) do
    {pairs, ids} =
      Enum.map_reduce(definitions, ids, fn
        %Gherkin.Scenario{} = scenario, ids -> build_scenario(scenario, ids)
        %Gherkin.ScenarioOutline{} = outline, ids -> build_outline(outline, ids)
      end)

    {children, sources} = Enum.unzip(pairs)
    {children, sources, ids}
  end

  defp build_scenario(scenario, ids) do
    {tag_entries, ids} = build_tags(scenario.tags, scenario.line, ids)
    {step_entries, ids} = build_steps(scenario.steps, ids)
    {id, ids} = next(ids)

    child = %{
      scenario: %{
        id: id,
        location: location(scenario.line),
        keyword: scenario.keyword,
        name: scenario.name,
        description: scenario.description,
        tags: Enum.map(tag_entries, & &1.tag),
        steps: Enum.map(step_entries, & &1.node),
        examples: []
      }
    }

    source = %{
      kind: :scenario,
      scenario: scenario,
      id: id,
      tag_entries: tag_entries,
      step_entries: step_entries
    }

    {{child, source}, ids}
  end

  defp build_outline(outline, ids) do
    {tag_entries, ids} = build_tags(outline.tags, outline.line, ids)
    {step_entries, ids} = build_steps(outline.steps, ids)
    {examples_entries, ids} = Enum.map_reduce(outline.examples, ids, &build_examples/2)
    {id, ids} = next(ids)

    child = %{
      scenario: %{
        id: id,
        location: location(outline.line),
        keyword: outline.keyword,
        name: outline.name,
        description: outline.description,
        tags: Enum.map(tag_entries, & &1.tag),
        steps: Enum.map(step_entries, & &1.node),
        examples: Enum.map(examples_entries, & &1.node)
      }
    }

    source = %{
      kind: :outline,
      scenario: outline,
      id: id,
      tag_entries: tag_entries,
      step_entries: step_entries,
      examples_entries: examples_entries
    }

    {{child, source}, ids}
  end

  defp build_examples(examples, ids) do
    {tag_entries, ids} = build_tags(examples.tags, examples.line, ids)

    header_line = examples.table_header_line || row_line(examples.line, 0)
    {header_row, ids} = build_table_row(examples.table_header, header_line, ids)

    {body_rows, ids} =
      examples.table_body
      |> Enum.with_index(1)
      |> Enum.map_reduce(ids, fn {row, index}, ids ->
        build_table_row(row, body_row_line(examples, index), ids)
      end)

    {id, ids} = next(ids)

    node = %{
      id: id,
      location: location(examples.line),
      keyword: examples.keyword,
      name: examples.name,
      description: examples.description,
      tags: Enum.map(tag_entries, & &1.tag),
      tableHeader: header_row,
      tableBody: body_rows
    }

    entry = %{
      node: node,
      examples: examples,
      row_ids: Enum.map(body_rows, & &1.id),
      tag_entries: tag_entries
    }

    {entry, ids}
  end

  # Fallback for hand-built ASTs without recorded lines: assume rows sit
  # on consecutive lines after their owner. Parsed features carry real
  # lines (Examples.table_body_lines, Step.datatable_lines/docstring_line).
  defp row_line(nil, _offset), do: nil
  defp row_line(owner_line, offset), do: owner_line + 1 + offset

  defp body_row_line(examples, index) do
    real = examples.table_body_lines && Enum.at(examples.table_body_lines, index - 1)
    real || row_line(examples.line, index)
  end

  defp datatable_row_line(step, index) do
    real = step.datatable_lines && Enum.at(step.datatable_lines, index)
    real || row_line(step.line, index)
  end

  defp build_table_row(cells, line, ids) do
    {id, ids} = next(ids)

    row = %{
      id: id,
      location: location(line),
      cells: Enum.map(cells, fn value -> %{location: location(line), value: value} end)
    }

    {row, ids}
  end

  defp build_steps(steps, ids) do
    Enum.map_reduce(steps, ids, fn step, ids ->
      {node, ids} = build_step_node(step, ids)
      {%{node: node, step: step, id: node.id}, ids}
    end)
  end

  defp build_step_node(step, ids) do
    {argument, ids} = build_step_argument(step, ids)
    {id, ids} = next(ids)

    node =
      Map.merge(
        %{
          id: id,
          location: location(step.line),
          keyword: step.keyword <> " ",
          keywordType: keyword_type(step.keyword),
          text: step.text
        },
        argument
      )

    {node, ids}
  end

  defp build_step_argument(%{docstring: docstring} = step, ids) when is_binary(docstring) do
    line = step.docstring_line || row_line(step.line, 0)

    doc_string =
      %{location: location(line), content: docstring}
      |> put_unless_nil(:mediaType, step.docstring_media_type)

    {%{docString: doc_string}, ids}
  end

  defp build_step_argument(%{datatable: [_ | _] = datatable} = step, ids) do
    {rows, ids} =
      datatable
      |> Enum.with_index()
      |> Enum.map_reduce(ids, fn {row, index}, ids ->
        build_table_row(row, datatable_row_line(step, index), ids)
      end)

    {%{dataTable: %{location: location(datatable_row_line(step, 0)), rows: rows}}, ids}
  end

  defp build_step_argument(_step, ids), do: {%{}, ids}

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  # Step keyword classification per the messages StepKeywordType enum.
  defp keyword_type("Given"), do: "Context"
  defp keyword_type("When"), do: "Action"
  defp keyword_type("Then"), do: "Outcome"
  defp keyword_type(conjunction) when conjunction in ["And", "But"], do: "Conjunction"
  defp keyword_type(_star_or_other), do: "Unknown"

  # Pickle step type: conjunctions resolve to the preceding step's type.
  defp step_type("Given", _previous), do: :context
  defp step_type("When", _previous), do: :action
  defp step_type("Then", _previous), do: :outcome
  defp step_type(conjunction, previous) when conjunction in ["And", "But"], do: previous
  defp step_type(_star_or_other, _previous), do: :unknown

  defp build_rules(rules, ids) do
    {pairs, ids} =
      Enum.map_reduce(rules, ids, fn rule, ids ->
        {rule_tag_entries, ids} = build_tags(rule.tags, rule.line, ids)

        {background_children, background_source, ids} =
          build_background_child(rule.background, ids)

        {scenario_children, scenario_sources, ids} =
          build_scenario_definitions(rule.scenarios, ids)

        {id, ids} = next(ids)

        child = %{
          rule: %{
            id: id,
            location: location(rule.line),
            keyword: "Rule",
            name: rule.name,
            description: rule.description,
            tags: Enum.map(rule_tag_entries, & &1.tag),
            children: background_children ++ scenario_children
          }
        }

        rule_info = %{
          rule: rule,
          tag_entries: rule_tag_entries,
          background_source: background_source
        }

        {{child, {rule_info, scenario_sources}}, ids}
      end)

    {children, source_groups} = Enum.unzip(pairs)
    {children, source_groups, ids}
  end

  # ============================================================
  # Pickles
  # ============================================================

  defp build_pickles(sources, background_source, feature_tags, uri, ids) do
    Enum.flat_map_reduce(sources, ids, fn source, ids ->
      case source.kind do
        :scenario -> build_scenario_pickle(source, background_source, feature_tags, uri, ids)
        :outline -> build_outline_pickles(source, background_source, feature_tags, uri, ids)
      end
    end)
  end

  defp build_scenario_pickle(source, background_source, feature_tags, uri, ids) do
    scenario = source.scenario

    step_sources = pickle_step_sources(source, background_source)
    {pickle_steps, ids} = build_pickle_steps(step_sources, %{}, nil, ids)
    {id, ids} = next(ids)

    pickle = %Pickle{
      id: id,
      uri: uri,
      name: scenario.name,
      line: scenario.line,
      ast_node_ids: [source.id],
      tags: pickle_tags(feature_tags, source),
      steps: pickle_steps,
      scenario_name: scenario.name,
      scenario_line: scenario.line,
      rule_name: rule_name(source),
      own_tags: own_tags(source)
    }

    {[pickle], ids}
  end

  defp build_outline_pickles(%{examples_entries: []} = source, _background, _tags, _uri, _ids) do
    raise """
    Scenario Outline '#{source.scenario.name}' has no Examples section.

    Every Scenario Outline must have at least one Examples block with data rows.
    """
  end

  defp build_outline_pickles(source, background_source, feature_tags, uri, ids) do
    outline = source.scenario
    step_sources = pickle_step_sources(source, background_source)

    Enum.flat_map_reduce(source.examples_entries, ids, fn examples_entry, ids ->
      examples = examples_entry.examples

      examples.table_body
      |> Enum.with_index(1)
      |> Enum.flat_map_reduce(ids, fn {row, row_index}, ids ->
        substitutions = examples.table_header |> Enum.zip(row) |> Map.new()
        row_id = Enum.at(examples_entry.row_ids, row_index - 1)

        {pickle_steps, ids} = build_pickle_steps(step_sources, substitutions, row_id, ids)
        {id, ids} = next(ids)

        pickle = %Pickle{
          id: id,
          uri: uri,
          name: substitute_placeholders(outline.name, substitutions),
          line: body_row_line(examples, row_index),
          ast_node_ids: [source.id, row_id],
          tags: pickle_tags(feature_tags, source, examples_entry),
          steps: pickle_steps,
          scenario_name: outline.name,
          scenario_line: outline.line,
          rule_name: rule_name(source),
          examples_name: examples.name,
          row_index: row_index,
          own_tags: own_tags(source, examples_entry)
        }

        {[pickle], ids}
      end)
    end)
  end

  # The step material a pickle draws from: feature background steps
  # (marked — the runner reports background failures distinctly), then
  # rule background steps, then the scenario's own steps. Only the
  # scenario's own steps (`own: true`) undergo outline substitution and
  # reference the examples row — reference compiler semantics; inherited
  # background steps pass through verbatim.
  #
  # A scenario with no steps of its own compiles to an empty pickle:
  # per the reference compiler, background steps alone are not a test
  # case (the runner accordingly skips the background too).
  defp pickle_step_sources(%{step_entries: []}, _background_source), do: []

  defp pickle_step_sources(source, background_source) do
    background_entries = background_entries(background_source)
    rule_background_entries = background_entries(rule_background_source(source))

    Enum.map(background_entries, &Map.merge(&1, %{from_background: true, own: false})) ++
      Enum.map(rule_background_entries, &Map.merge(&1, %{from_background: false, own: false})) ++
      Enum.map(source.step_entries, &Map.merge(&1, %{from_background: false, own: true}))
  end

  defp background_entries(nil), do: []
  defp background_entries(%{step_entries: entries}), do: entries

  defp rule_background_source(%{rule: nil}), do: nil
  defp rule_background_source(%{rule: rule_info}), do: rule_info.background_source

  defp rule_name(%{rule: nil}), do: nil
  defp rule_name(%{rule: rule_info}), do: rule_info.rule.name

  # Pickle step types thread across the whole pickle (background steps
  # included), so a scenario starting with And/But inherits the type of
  # the last background step — reference compiler semantics.
  defp build_pickle_steps(step_sources, substitutions, row_id, ids) do
    {pickle_steps, {ids, _previous_type}} =
      Enum.map_reduce(step_sources, {ids, :unknown}, fn entry, {ids, previous_type} ->
        type = step_type(entry.step.keyword, previous_type)
        step = if entry.own, do: substitute_step(entry.step, substitutions), else: entry.step
        ast_node_ids = if entry.own, do: [entry.id] ++ List.wrap(row_id), else: [entry.id]
        {id, ids} = next(ids)

        pickle_step = %PickleStep{
          id: id,
          text: step.text,
          type: type,
          ast_node_ids: ast_node_ids,
          step: step,
          from_background: entry.from_background
        }

        {pickle_step, {ids, type}}
      end)

    {pickle_steps, ids}
  end

  # Pickle tags: everything in effect, outermost first (feature, rule,
  # outline/scenario, examples), referencing the document tag ids.
  defp pickle_tags(feature_tags, source, examples_entry \\ nil) do
    rule_tag_entries =
      case source.rule do
        nil -> []
        rule_info -> rule_info.tag_entries
      end

    examples_tag_entries = if examples_entry, do: examples_entry.tag_entries, else: []

    (feature_tags ++ rule_tag_entries ++ source.tag_entries ++ examples_tag_entries)
    |> Enum.map(fn entry -> %{name: "@" <> entry.name, ast_node_id: entry.id} end)
  end

  # The scenario's effective own tags for test generation, most specific
  # first — first match wins for @retry-n, so precedence is examples >
  # outline > rule (feature tags travel separately as module tags).
  defp own_tags(source, examples_entry \\ nil) do
    examples_tags = if examples_entry, do: tag_names(examples_entry.tag_entries), else: []

    rule_tags =
      case source.rule do
        nil -> []
        rule_info -> tag_names(rule_info.tag_entries)
      end

    Enum.uniq(examples_tags ++ tag_names(source.tag_entries) ++ rule_tags)
  end

  defp tag_names(tag_entries), do: Enum.map(tag_entries, & &1.name)

  # ============================================================
  # Outline substitution
  # ============================================================

  defp substitute_step(step, substitutions) when substitutions == %{}, do: step

  defp substitute_step(%Gherkin.Step{} = step, substitutions) do
    %{
      step
      | text: substitute_placeholders(step.text, substitutions),
        docstring: substitute_placeholders(step.docstring, substitutions),
        docstring_media_type: substitute_placeholders(step.docstring_media_type, substitutions),
        datatable: substitute_datatable(step.datatable, substitutions)
    }
  end

  defp substitute_placeholders(nil, _substitutions), do: nil

  defp substitute_placeholders(text, substitutions) do
    Enum.reduce(substitutions, text, fn {key, value}, acc ->
      String.replace(acc, "<#{key}>", value)
    end)
  end

  defp substitute_datatable(nil, _substitutions), do: nil

  defp substitute_datatable(table, substitutions) do
    Enum.map(table, fn row ->
      Enum.map(row, &substitute_placeholders(&1, substitutions))
    end)
  end
end
