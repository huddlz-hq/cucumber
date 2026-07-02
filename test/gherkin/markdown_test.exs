defmodule Gherkin.MarkdownTest do
  use ExUnit.Case, async: true

  alias Gherkin.Markdown

  describe "parse/2 dispatch" do
    test ".feature.md paths parse as Markdown, others as plain Gherkin" do
      markdown = "# Feature: MD\n\n## Scenario: s\n\n* Given a step\n"
      plain = "Feature: Plain\n\nScenario: s\n  Given a step\n"

      assert %Gherkin.Feature{name: "MD"} = Gherkin.Parser.parse(markdown, "cheese.feature.md")
      assert %Gherkin.Feature{name: "Plain"} = Gherkin.Parser.parse(plain, "cheese.feature")
    end
  end

  describe "the CCK markdown sample" do
    test "parses with the reference structure and source line numbers" do
      feature = Markdown.parse(File.read!("test/fixtures/cck/markdown/markdown.feature.md"))

      assert feature.name == "Cheese"
      assert feature.line == 0
      assert feature.description == ""
      assert feature.comments == []
      assert feature.scenarios == []

      assert [rule] = feature.rules
      assert rule.name == "Nom nom nom"
      assert rule.line == 9

      assert [outline] = rule.scenarios
      assert outline.keyword == "Scenario Outline"
      assert outline.name == "Ylajali!"
      assert outline.line == 13

      assert [given, conjunction, when_step, then_step] = outline.steps

      assert %{keyword: "Given", text: "some TypeScript code:", line: 15} = given
      assert given.docstring == "type Cheese = 'reblochon' | 'roquefort' | 'rocamadour'"
      assert given.docstring_media_type == "typescript"
      assert given.docstring_line == 16
      assert given.docstring_delimiter == "```"

      assert %{keyword: "And", text: "some classic Gherkin:", line: 19} = conjunction
      assert conjunction.docstring == "Given there are 24 apples in Mary's basket"
      assert conjunction.docstring_media_type == "gherkin"

      assert when_step.text == "we use a data table and attach something and then <what>"
      # The GFM separator row (line 25 in the file) is excluded; the
      # remaining rows keep their real source lines.
      assert when_step.datatable == [["name", "age"], ["Bill", "3"], ["Jane", "6"], ["Isla", "5"]]
      assert when_step.datatable_lines == [24, 26, 27, 28]

      assert %{keyword: "Then", text: "this might or might not run", line: 29} = then_step

      assert [examples] = outline.examples
      assert examples.name == "because we need more tables"
      assert examples.line == 31
      assert examples.table_header == ["what"]
      assert examples.table_header_line == 35
      assert examples.table_body == [["fail"], ["pass"]]
      assert examples.table_body_lines == [37, 38]
    end
  end

  describe "section headings" do
    test "heading level is decorative — keywords alone define nesting" do
      feature =
        Markdown.parse("""
        ###### Feature: Deep
        # Scenario: level does not matter
        * Given a step
        """)

      assert feature.name == "Deep"
      assert [%{name: "level does not matter", steps: [_]}] = feature.scenarios
    end

    test "keyword synonyms: Example, Scenario Template, Scenarios" do
      feature =
        Markdown.parse("""
        # Feature: Synonyms
        ## Example: a concrete example
        * Given a step
        ## Scenario Template: a template
        * Given a <thing>
        ### Scenarios: values
          | thing |
          | boat  |
        """)

      assert [scenario, outline] = feature.scenarios
      assert %Gherkin.Scenario{keyword: "Example", name: "a concrete example"} = scenario
      assert %Gherkin.ScenarioOutline{keyword: "Scenario Template"} = outline
      assert [%Gherkin.Examples{keyword: "Scenarios", table_header: ["thing"]}] = outline.examples
    end

    test "headings without a Gherkin keyword are prose" do
      feature =
        Markdown.parse("""
        # Feature: Prose headings
        ## Notes
        ### Scenario: still found
        * Given a step
        """)

      assert [%{name: "still found"}] = feature.scenarios
    end

    test "a second Feature heading is ignored" do
      feature =
        Markdown.parse("""
        # Feature: First
        # Feature: Second
        ## Scenario: s
        * Given a step
        """)

      assert feature.name == "First"
      assert [%{name: "s"}] = feature.scenarios
    end

    test "rules group scenarios and can have their own background" do
      feature =
        Markdown.parse("""
        # Feature: Rules
        ## Background:
        * Given feature setup
        ## Scenario: bare
        * Given a step
        ## Rule: first rule
        ### Background:
        * Given rule setup
        ### Scenario: ruled
        * Given another step
        """)

      assert [%{name: "bare"}] = feature.scenarios
      assert feature.background.steps |> hd() |> Map.get(:text) == "feature setup"

      assert [rule] = feature.rules
      assert rule.name == "first rule"
      assert rule.background.steps |> hd() |> Map.get(:text) == "rule setup"
      assert [%{name: "ruled"}] = rule.scenarios
    end
  end

  describe "the feature line" do
    test "a non-heading first line becomes the feature name (reference fallback)" do
      feature =
        Markdown.parse("""
        Just some notes
        ## Scenario: s
        * Given a step
        """)

      assert feature.name == "Just some notes"
      assert feature.line == 0
      assert [%{name: "s"}] = feature.scenarios
    end

    test "a non-Gherkin heading first line is taken whole, hashes included" do
      feature = Markdown.parse("# Hello world\n")
      assert feature.name == "# Hello world"
    end

    test "a blank first line becomes an unnamed feature" do
      feature = Markdown.parse("\n# Feature: too late\n## Scenario: s\n* Given a step\n")
      assert feature.name == ""
      assert [%{name: "s"}] = feature.scenarios
    end
  end

  describe "steps" do
    test "asterisk, dash, and plus bullets all introduce steps" do
      feature =
        Markdown.parse("""
        # Feature: Bullets
        ## Scenario: s
        * Given a star step
        - When a dash step
        + Then a plus step
          * And an indented step
        * But a but step
        """)

      [scenario] = feature.scenarios

      assert Enum.map(scenario.steps, &{&1.keyword, &1.text, &1.line}) == [
               {"Given", "a star step", 2},
               {"When", "a dash step", 3},
               {"Then", "a plus step", 4},
               {"And", "an indented step", 5},
               {"But", "a but step", 6}
             ]
    end

    test "bullets without a step keyword are prose, including the * keyword" do
      feature =
        Markdown.parse("""
        # Feature: Lists
        ## Scenario: s
        * Given a real step
        * just a list item
        * * the star keyword is not available in Markdown
        - Givenwithoutspace is not a keyword
        """)

      [scenario] = feature.scenarios
      assert [%{text: "a real step"}] = scenario.steps
    end

    test "a step before any Scenario or Background raises" do
      assert_raise Gherkin.ParseError, ~r/line 2.*Scenario or Background/s, fn ->
        Markdown.parse("""
        # Feature: Loose step
        * Given a step with no home
        """)
      end
    end

    test "a step after an Examples table raises" do
      assert_raise Gherkin.ParseError, ~r/before the Examples/s, fn ->
        Markdown.parse("""
        # Feature: Late step
        ## Scenario Outline: o
        * Given a <thing>
        ### Examples:
          | thing |
          | boat  |
        * When too late
        """)
      end
    end
  end

  describe "data tables" do
    test "rows indented two to five spaces attach to the step; others are prose" do
      feature =
        Markdown.parse("""
        # Feature: Tables
        ## Scenario: s
        * Given a table:
          | two spaces |
             | five spaces |
              | six spaces is prose |
        | no indent is prose |
        """)

      [%{steps: [step]}] = feature.scenarios
      assert step.datatable == [["two spaces"], ["five spaces"]]
      assert step.datatable_lines == [3, 4]
    end

    test "GFM separator rows are skipped, alignment colons included" do
      feature =
        Markdown.parse("""
        # Feature: Separators
        ## Scenario: s
        * Given a table:
          | name | age |
          | :--- | --: |
          | Bill |   3 |
        """)

      [%{steps: [step]}] = feature.scenarios
      assert step.datatable == [["name", "age"], ["Bill", "3"]]
      assert step.datatable_lines == [3, 5]
    end

    test "an indented table row with nothing to attach to raises" do
      assert_raise Gherkin.ParseError, ~r/before a table row/s, fn ->
        Markdown.parse("""
        # Feature: Orphan table
        ## Scenario: s
          | orphan |
        """)
      end
    end
  end

  describe "docstrings" do
    test "a fenced code block under a step becomes its docstring" do
      feature =
        Markdown.parse("""
        # Feature: Fences
        ## Scenario: s
        * Given some code:
          ```elixir
          defmodule Deep do
            :nested
          end
          ```
        * And plain text:
          ```
          no media type
          ```
        """)

      [%{steps: [given, conjunction]}] = feature.scenarios

      # Content is dedented by the fence's own indentation, preserving
      # deeper relative indentation.
      assert given.docstring == "defmodule Deep do\n  :nested\nend"
      assert given.docstring_media_type == "elixir"
      assert given.docstring_line == 3
      assert given.docstring_delimiter == "```"

      assert conjunction.docstring == "no media type"
      assert conjunction.docstring_media_type == nil
    end

    test "a longer fence wraps a shorter one literally" do
      feature =
        Markdown.parse("""
        # Feature: Nested fences
        ## Scenario: s
        * Given markdown about markdown:
          ````markdown
          ```
          inner
          ```
          ````
        """)

      [%{steps: [step]}] = feature.scenarios
      assert step.docstring == "```\ninner\n```"
      assert step.docstring_delimiter == "````"
    end

    test "a fenced code block in prose is skipped, even when it contains step bullets" do
      feature =
        Markdown.parse("""
        # Feature: Prose fences
        How to write a step:
        ```markdown
        * Given a step that must not parse
        ```
        ## Scenario: s
        * Given the only real step
        """)

      [%{steps: [step]}] = feature.scenarios
      assert step.text == "the only real step"
    end

    test "a second fenced code block on one step raises" do
      assert_raise Gherkin.ParseError, ~r/single docstring/s, fn ->
        Markdown.parse("""
        # Feature: Greedy step
        ## Scenario: s
        * Given code:
          ```
          one
          ```
          ```
          two
          ```
        """)
      end
    end

    test "an unclosed fence raises" do
      assert_raise Gherkin.ParseError, ~r/closing ``` fence/s, fn ->
        Markdown.parse("""
        # Feature: Unclosed
        ## Scenario: s
        * Given code:
          ```
          never closed
        """)
      end
    end
  end

  describe "examples tables" do
    test "multiple Examples blocks with names and tags" do
      feature =
        Markdown.parse("""
        # Feature: Outlines
        ## Scenario Outline: o
        * Given a <thing>

        ### Examples: watercraft
          | thing |
          | ----- |
          | boat  |

        `@lorries`
        ### Examples: road vehicles
          | thing |
          | truck |
        """)

      [outline] = feature.scenarios
      assert [watercraft, road] = outline.examples

      assert watercraft.name == "watercraft"
      assert watercraft.table_header == ["thing"]
      assert watercraft.table_header_line == 5
      assert watercraft.table_body == [["boat"]]
      assert watercraft.table_body_lines == [7]

      assert road.name == "road vehicles"
      assert road.tags == ["lorries"]
      assert road.tag_lines == [9]
      assert road.table_body == [["truck"]]
    end

    test "an Examples heading outside a Scenario Outline raises" do
      assert_raise Gherkin.ParseError, ~r/Scenario Outline before an Examples/s, fn ->
        Markdown.parse("""
        # Feature: Misplaced
        ## Scenario: not an outline
        * Given a step
        ### Examples:
          | thing |
        """)
      end
    end
  end

  describe "backgrounds" do
    test "a Background after the first scenario raises" do
      assert_raise Gherkin.ParseError, ~r/Background before the first Scenario/s, fn ->
        Markdown.parse("""
        # Feature: Late background
        ## Scenario: s
        * Given a step
        ## Background:
        * Given too late
        """)
      end
    end

    test "a second Background raises" do
      assert_raise Gherkin.ParseError, ~r/single Background/s, fn ->
        Markdown.parse("""
        # Feature: Two backgrounds
        ## Background:
        * Given one
        ## Background:
        * Given two
        """)
      end
    end
  end

  describe "tags" do
    test "backticked tags attach to the next section; bare @tags are prose" do
      feature =
        Markdown.parse("""
        `@billing` `@critical`
        # Feature: Tagged

        @prose is not a tag

        `@wip`
        `@slow`
        ## Scenario: s
        * Given a step

        `@ruled`
        ## Rule: r
        ### Scenario: inside
        * Given a step
        """)

      assert feature.tags == ["billing", "critical"]
      assert feature.tag_lines == [0, 0]

      [scenario] = feature.scenarios
      assert scenario.tags == ["wip", "slow"]
      assert scenario.tag_lines == [5, 6]

      [rule] = feature.rules
      assert rule.tags == ["ruled"]
    end
  end

  describe "descriptions and comments" do
    test "prose is ignored: descriptions stay empty and there are no comments" do
      feature =
        Markdown.parse("""
        # Feature: Prose
        Everything here is prose.

        | unindented | table |
        | ---------- | ----- |
        | is         | prose |

        ## Rule: r
        Rule prose.
        ### Scenario: s
        Scenario prose. # not a comment either
        * Given a step
        """)

      assert feature.description == ""
      assert feature.comments == []
      assert [%{description: "", scenarios: [%{description: ""}]}] = feature.rules
    end
  end
end
