defmodule GherkinDescriptionsTest do
  use ExUnit.Case, async: true

  alias Gherkin.Parser

  describe "feature descriptions" do
    test "feature description is captured" do
      feature =
        Parser.parse("""
        Feature: Described
          This is the first line.
          This is the second line.

          Scenario: one
            Given a step
        """)

      assert feature.description == "This is the first line.\nThis is the second line."
    end

    test "interior blank lines are preserved, leading/trailing blanks dropped" do
      feature =
        Parser.parse("""
        Feature: Described

          Paragraph one.

          Paragraph two.

          Scenario: one
            Given a step
        """)

      assert feature.description == "Paragraph one.\n\nParagraph two."
    end

    test "step-keyword-like lines and bullets remain feature description" do
      # At feature level there are no steps, so * bullets and lines starting
      # with Given/When/Then are still description (CCK minimal.feature shape).
      feature =
        Parser.parse("""
        Feature: minimal

          Cucumber doesn't execute this markdown, but it renders it.

          * This is
          * a bullet
          * list

          Given the chance, this line also stays description.

          Scenario: cukes
            Given a step
        """)

      assert feature.description =~ "* This is\n* a bullet\n* list"
      assert feature.description =~ "Given the chance"
      assert [%Gherkin.Scenario{steps: [step]}] = feature.scenarios
      assert step.text == "a step"
    end

    test "comment lines are excluded from descriptions" do
      feature =
        Parser.parse("""
        Feature: Described
          Real description.
          # this is a comment, not description

          Scenario: one
            Given a step
        """)

      assert feature.description == "Real description."
    end

    test "a feature with a description and no scenarios parses (no hang at EOF)" do
      feature = Parser.parse("Feature: lonely\n  Just a description, nothing else.")

      assert feature.description == "Just a description, nothing else."
      assert feature.scenarios == []
    end
  end

  describe "section descriptions" do
    test "background description is captured and steps still run" do
      feature =
        Parser.parse("""
        Feature: F

          Background:
            Why this background exists,
            in two lines.

            Given some setup

          Scenario: one
            Given a step
        """)

      assert feature.background.description == "Why this background exists,\nin two lines."
      assert [%Gherkin.Step{text: "some setup"}] = feature.background.steps
    end

    test "scenario description is captured; description never becomes steps" do
      feature =
        Parser.parse("""
        Feature: F

          Scenario: described
            Beware that some formatters use the media type
            to determine how to display things.

            Given a real step
            And another real step
        """)

      [scenario] = feature.scenarios

      assert scenario.description ==
               "Beware that some formatters use the media type\nto determine how to display things."

      assert Enum.map(scenario.steps, & &1.text) == ["a real step", "another real step"]
    end

    test "a description line containing a step keyword mid-sentence stays description" do
      feature =
        Parser.parse("""
        Feature: F

          Scenario: described
            You are Given a chance to read this prose.

            Given a real step
        """)

      [scenario] = feature.scenarios
      assert scenario.description == "You are Given a chance to read this prose."
      assert [%Gherkin.Step{text: "a real step"}] = scenario.steps
    end

    test "a line starting with a step-keyword-prefixed word stays description" do
      # "Givenness" starts with "Given" but is not followed by whitespace,
      # so it is not a step.
      feature =
        Parser.parse("""
        Feature: F

          Scenario: described
            Givenness is not a step keyword.

            Given a real step
        """)

      [scenario] = feature.scenarios
      assert scenario.description == "Givenness is not a step keyword."
      assert [%Gherkin.Step{text: "a real step"}] = scenario.steps
    end

    test "scenario outline and examples descriptions are captured" do
      feature =
        Parser.parse("""
        Feature: F

          Scenario Outline: described outline
            The outline description.

            Given <thing>

            Examples: described examples
              The examples description.

              | thing |
              | a     |
        """)

      [outline] = feature.scenarios
      assert outline.description == "The outline description."
      assert [examples] = outline.examples
      assert examples.description == "The examples description."
      assert examples.table_header == ["thing"]
      assert examples.table_body == [["a"]]
    end

    test "scenarios without descriptions get an empty string" do
      feature =
        Parser.parse("""
        Feature: F
          Scenario: plain
            Given a step
        """)

      [scenario] = feature.scenarios
      assert scenario.description == ""
      assert feature.description == ""
    end

    test "previously-failing CCK fixtures with scenario descriptions now parse" do
      for fixture <- ["attachments/attachments.feature", "hooks-skipped/hooks-skipped.feature"] do
        feature =
          Path.join("test/fixtures/cck", fixture)
          |> File.read!()
          |> Parser.parse()

        assert feature.scenarios != [], "#{fixture} parsed no scenarios"
      end
    end
  end

  describe "docstring delimiters and media types" do
    test "backtick docstrings deliver the same content as triple quotes" do
      standard =
        Parser.parse("""
        Feature: F
          Scenario: s
            Given a doc string:
              \"\"\"
              Here is some content
              And some more on another line
              \"\"\"
        """)

      backtick =
        Parser.parse("""
        Feature: F
          Scenario: s
            Given a doc string:
              ```
              Here is some content
              And some more on another line
              ```
        """)

      [%{steps: [standard_step]}] = standard.scenarios
      [%{steps: [backtick_step]}] = backtick.scenarios

      assert standard_step.docstring == "Here is some content\nAnd some more on another line"
      assert backtick_step.docstring == standard_step.docstring
    end

    test "media type is captured for both delimiters and nil when absent" do
      feature =
        Parser.parse("""
        Feature: F
          Scenario: s
            Given a json doc string:
              \"\"\"application/json
              {"foo": "bar"}
              \"\"\"
            And a ruby doc string:
              ```ruby
              puts "hi"
              ```
            And a plain doc string:
              \"\"\"
              plain
              \"\"\"
        """)

      [%{steps: [json_step, ruby_step, plain_step]}] = feature.scenarios

      assert json_step.docstring_media_type == "application/json"
      assert json_step.docstring == ~s({"foo": "bar"})
      assert ruby_step.docstring_media_type == "ruby"
      assert plain_step.docstring_media_type == nil
    end

    test "each delimiter style is literal content inside the other" do
      feature =
        Parser.parse("""
        Feature: F
          Scenario: s
            Given a doc string:
              \"\"\"
              what is `backtick` ```
              \"\"\"
            And another doc string:
              ```
              triple quote: \"\"\"
              ```
        """)

      [%{steps: [first, second]}] = feature.scenarios
      assert first.docstring == "what is `backtick` ```"
      assert second.docstring == ~s(triple quote: """)
    end

    test "backtick docstrings dedent the same way as standard ones" do
      feature =
        Parser.parse("""
        Feature: F
          Scenario: s
            Given a doc string:
              ```
              first
                indented relative
              first again
              ```
        """)

      [%{steps: [step]}] = feature.scenarios
      assert step.docstring == "first\n  indented relative\nfirst again"
    end

    test "the CCK doc-strings fixture parses with all three scenarios" do
      feature =
        "test/fixtures/cck/doc-strings/doc-strings.feature"
        |> File.read!()
        |> Parser.parse()

      assert length(feature.scenarios) == 3

      [standard, backtick, media] = feature.scenarios
      assert standard.steps |> hd() |> Map.fetch!(:docstring) =~ "Here is some content"
      assert backtick.steps |> hd() |> Map.fetch!(:docstring) =~ "Here is some content"
      assert media.steps |> hd() |> Map.fetch!(:docstring_media_type) == "application/json"
    end
  end
end
