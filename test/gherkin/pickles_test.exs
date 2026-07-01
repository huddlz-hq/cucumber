defmodule Gherkin.PicklesTest do
  use ExUnit.Case, async: true

  alias Gherkin.{Pickle, Pickles, PickleStep}

  defp compile(source, opts \\ []) do
    file = Keyword.get(opts, :file, "test/fixtures/generated/pickles_test.feature")
    start_id = Keyword.get(opts, :start_id, 0)

    source
    |> Gherkin.Parser.parse()
    |> Map.put(:file, file)
    |> Pickles.compile(start_id)
  end

  # All ids assigned anywhere in the document (nodes, tags, rows).
  defp document_ids(node) when is_map(node) do
    own = if Map.has_key?(node, :id), do: [node.id], else: []
    own ++ Enum.flat_map(Map.values(node), &document_ids/1)
  end

  defp document_ids(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &document_ids/1)
  defp document_ids(_other), do: []

  describe "plain scenarios" do
    test "one scenario compiles to one pickle referencing its document nodes" do
      %{document: document, pickles: [pickle]} =
        compile("""
        Feature: minimal
          Scenario: cukes
            Given I have 42 cukes in my belly
        """)

      [%{scenario: scenario_node}] = document.children
      [step_node] = scenario_node.steps

      assert %Pickle{name: "cukes", scenario_name: "cukes", rule_name: nil} = pickle
      assert pickle.uri == "test/fixtures/generated/pickles_test.feature"
      assert pickle.language == "en"
      assert pickle.ast_node_ids == [scenario_node.id]

      assert [%PickleStep{text: "I have 42 cukes in my belly", type: :context} = pickle_step] =
               pickle.steps

      assert pickle_step.ast_node_ids == [step_node.id]
      refute pickle_step.from_background

      # Pickle and pickle-step ids continue the document's sequence
      assert pickle.id not in document_ids(document)
      assert pickle_step.id not in document_ids(document)
    end

    test "document nodes carry locations, keywords, and descriptions" do
      %{document: document} =
        compile("""
        Feature: shapes

          A feature description.

          Example: renamed keyword
            Given a step
        """)

      assert document.keyword == "Feature"
      assert document.language == "en"
      assert document.location == %{line: 1}
      assert document.description == "A feature description."

      [%{scenario: scenario_node}] = document.children
      assert scenario_node.keyword == "Example"
      assert scenario_node.location == %{line: 5}

      [step_node] = scenario_node.steps
      assert step_node.keyword == "Given "
      assert step_node.keywordType == "Context"
      assert step_node.location == %{line: 6}
    end

    test "conjunctions resolve to the preceding step's type" do
      %{pickles: [pickle]} =
        compile("""
        Feature: keyword types
          Scenario: all of them
            Given a context
            And another context
            When an action
            But another action
            Then an outcome
            And another outcome
        """)

      assert Enum.map(pickle.steps, & &1.type) ==
               [:context, :context, :action, :action, :outcome, :outcome]
    end
  end

  describe "backgrounds" do
    test "feature background steps come first and are marked; rule backgrounds are not" do
      %{pickles: [pickle]} =
        compile("""
        Feature: backgrounds
          Background:
            Given a feature background step

          Rule: with its own background
            Background:
              Given a rule background step

            Scenario: inherits both
              Given a scenario step
        """)

      assert Enum.map(pickle.steps, &{&1.text, &1.from_background}) == [
               {"a feature background step", true},
               {"a rule background step", false},
               {"a scenario step", false}
             ]
    end

    test "background steps are never placeholder-substituted and don't reference the row" do
      %{document: document, pickles: [pickle]} =
        compile("""
        Feature: literal background
          Background:
            Given a template containing <b> markup

          Scenario Outline: uses <b>
            Given I emphasise <b>

            Examples:
              | b     |
              | words |
        """)

      [background_step, own_step] = pickle.steps

      # The background step keeps its literal text — <b> is not an
      # outline placeholder there, even though the Examples table has
      # a matching column
      assert background_step.text == "a template containing <b> markup"
      assert own_step.text == "I emphasise words"

      # Only the outline's own step references the examples row
      [%{background: background_node}, %{scenario: outline_node}] = document.children
      [examples_node] = outline_node.examples
      [row] = examples_node.tableBody

      assert background_step.ast_node_ids == [hd(background_node.steps).id]
      assert own_step.ast_node_ids == [hd(outline_node.steps).id, row.id]
    end

    test "conjunction types thread across the background boundary" do
      %{pickles: [pickle]} =
        compile("""
        Feature: threading
          Background:
            Given a user

          Scenario: starts with a conjunction
            And an admin
            When something happens
        """)

      assert Enum.map(pickle.steps, & &1.type) == [:context, :context, :action]
    end

    test "a scenario with no steps of its own compiles to an empty pickle" do
      %{pickles: [pickle]} =
        compile("""
        Feature: empty scenario
          Background:
            Given setup

          Scenario: nothing yet
        """)

      assert pickle.steps == []
    end

    test "the background appears as a document child with its steps" do
      %{document: document} =
        compile("""
        Feature: bg
          Background: named setup
            Given a common step

          Scenario: one
            Given a step
        """)

      assert [%{background: background_node}, %{scenario: _}] = document.children
      assert background_node.keyword == "Background"
      assert background_node.name == "named setup"
      assert [%{text: "a common step"}] = background_node.steps
    end
  end

  describe "scenario outlines" do
    test "one pickle per examples row, across blocks, with substitution everywhere" do
      %{document: document, pickles: pickles} =
        compile("""
        Feature: outlines
          Scenario Outline: eating <count>
            Given I have <count> cukes
            And a note:
              \"\"\"
              exactly <count>
              \"\"\"
            And a table:
              | amount  |
              | <count> |

            Examples: small
              | count |
              | 1     |

            Examples: large
              | count |
              | 10    |
              | 42    |
        """)

      assert length(pickles) == 3
      [small, _large_one, large_two] = pickles

      # Names substitute placeholders (the messages-spec name), provenance
      # keeps the original
      assert small.name == "eating 1"
      assert small.scenario_name == "eating <count>"
      assert {small.examples_name, small.row_index} == {"small", 1}
      assert {large_two.examples_name, large_two.row_index} == {"large", 2}

      assert [step_one, note, table] = small.steps
      assert step_one.text == "I have 1 cukes"
      assert note.step.docstring == "exactly 1"
      assert table.step.datatable == [["amount"], ["1"]]

      assert hd(large_two.steps).text == "I have 42 cukes"

      # astNodeIds chain outline id and the examples-row id
      [%{scenario: outline_node}] = document.children
      [small_examples, large_examples] = outline_node.examples
      [small_row] = small_examples.tableBody
      [_large_row_one, large_row_two] = large_examples.tableBody

      assert small.ast_node_ids == [outline_node.id, small_row.id]
      assert large_two.ast_node_ids == [outline_node.id, large_row_two.id]

      # Each pickle step references its outline step and the row
      assert step_one.ast_node_ids == [hd(outline_node.steps).id, small_row.id]
    end

    test "docstring media types substitute placeholders" do
      %{pickles: [pickle]} =
        compile("""
        Feature: media types
          Scenario Outline: typed note
            Given a note:
              \"\"\"<fmt>
              payload
              \"\"\"

            Examples:
              | fmt  |
              | json |
        """)

      [note] = pickle.steps
      assert note.step.docstring_media_type == "json"
    end

    test "examples tables land in the document with header and body rows" do
      %{document: document} =
        compile("""
        Feature: tables
          Scenario Outline: t
            Given <a>

            Examples:
              | a |
              | 1 |
              | 2 |
        """)

      [%{scenario: outline_node}] = document.children
      [examples_node] = outline_node.examples

      assert examples_node.keyword == "Examples"
      assert [%{value: "a"}] = examples_node.tableHeader.cells
      assert [row_one, row_two] = examples_node.tableBody
      assert [%{value: "1"}] = row_one.cells
      assert [%{value: "2"}] = row_two.cells
    end

    test "an outline with no Examples raises" do
      outline = %Gherkin.ScenarioOutline{name: "Missing examples", examples: []}
      feature = %Gherkin.Feature{name: "f", scenarios: [outline]}

      assert_raise RuntimeError,
                   ~r/Scenario Outline 'Missing examples' has no Examples section/,
                   fn -> Pickles.compile(Map.put(feature, :file, "f.feature")) end
    end
  end

  describe "tags" do
    test "pickle tags collect every level with document references" do
      %{document: document, pickles: [pickle]} =
        compile("""
        @feature-tag
        Feature: tagged
          @rule-tag
          Rule: r
            @outline-tag
            Scenario Outline: o
              Given <a>

              @examples-tag
              Examples:
                | a |
                | 1 |
        """)

      assert Enum.map(pickle.tags, & &1.name) ==
               ["@feature-tag", "@rule-tag", "@outline-tag", "@examples-tag"]

      # Every referenced tag id exists in the document
      ids = document_ids(document)

      for tag <- pickle.tags do
        assert tag.ast_node_id in ids
      end
    end

    test "own_tags order is examples, then scenario/outline, then rule" do
      %{pickles: [pickle]} =
        compile("""
        @feature-tag
        Feature: tagged
          @rule-tag
          Rule: r
            @outline-tag
            Scenario Outline: o
              Given <a>

              @examples-tag
              Examples:
                | a |
                | 1 |
        """)

      assert pickle.own_tags == ["examples-tag", "outline-tag", "rule-tag"]
    end
  end

  describe "rules" do
    test "rule scenarios carry the rule name and appear after feature scenarios" do
      %{document: document, pickles: pickles} =
        compile("""
        Feature: with rules
          Scenario: bare
            Given a step

          Rule: business rule
            Scenario: ruled
              Given a step
        """)

      assert [%{rule_name: nil}, %{rule_name: "business rule"}] = pickles

      assert [%{scenario: _}, %{rule: rule_node}] = document.children
      assert rule_node.keyword == "Rule"
      assert rule_node.name == "business rule"
      assert [%{scenario: %{name: "ruled"}}] = rule_node.children
    end
  end

  describe "id assignment" do
    test "ids are unique, sequential from start_id, and referentially consistent" do
      %{document: document, pickles: pickles, next_id: next_id} =
        compile(
          """
          Feature: ids
            Background:
              Given setup

            @tagged
            Scenario: one
              Given a step
              And a table:
                | a |
                | 1 |

            Scenario Outline: two <n>
              Given step <n>

              Examples:
                | n |
                | 1 |
          """,
          start_id: 100
        )

      doc_ids = document_ids(document)
      pickle_ids = Enum.map(pickles, & &1.id)
      pickle_step_ids = Enum.flat_map(pickles, fn p -> Enum.map(p.steps, & &1.id) end)
      all_ids = doc_ids ++ pickle_ids ++ pickle_step_ids

      # Unique, and exactly the sequence [start_id, next_id)
      assert Enum.uniq(all_ids) == all_ids

      assert Enum.sort(Enum.map(all_ids, &String.to_integer/1)) ==
               Enum.to_list(100..(next_id - 1))

      # Everything a pickle references exists in the document
      referenced =
        Enum.flat_map(pickles, fn pickle ->
          pickle.ast_node_ids ++
            Enum.flat_map(pickle.steps, & &1.ast_node_ids) ++
            Enum.map(pickle.tags, & &1.ast_node_id)
        end)

      for id <- referenced do
        assert id in doc_ids
      end
    end
  end
end
