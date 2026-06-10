defmodule Gherkin.ParserTest do
  use ExUnit.Case, async: true

  alias Gherkin.{Background, Feature, Scenario, ScenarioOutline, Step}

  describe "parse/1" do
    test "parses a minimal feature file with one scenario and background" do
      gherkin = """
      Feature: User signs up for event

      Background:
        Given a logged in user

      Scenario: User joins an event
        Given an event titled \"Tech Gathering\"
        When I visit \"/\"
        Then I should see the event
        When I click \"join\" on the first event
        Then I should see \"joined event\"
      """

      expected = %Feature{
        name: "User signs up for event",
        description: "",
        background: %Background{
          steps: [
            %Step{
              keyword: "Given",
              text: "a logged in user",
              line: 3,
              docstring: nil,
              datatable: nil
            }
          ]
        },
        scenarios: [
          %Scenario{
            name: "User joins an event",
            line: 5,
            steps: [
              %Step{
                keyword: "Given",
                text: "an event titled \"Tech Gathering\"",
                line: 6,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "When",
                text: "I visit \"/\"",
                line: 7,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "Then",
                text: "I should see the event",
                line: 8,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "When",
                text: "I click \"join\" on the first event",
                line: 9,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "Then",
                text: "I should see \"joined event\"",
                line: 10,
                docstring: nil,
                datatable: nil
              }
            ]
          }
        ]
      }

      assert Gherkin.Parser.parse(gherkin) == expected
    end

    test "parses a feature file with multiple scenarios" do
      gherkin = """
      Feature: Multiple scenarios

      Scenario: First scenario
        Given something
        When I do something
        Then I see something

      Scenario: Second scenario
        Given another thing
        When I do another thing
        Then I see another thing
      """

      expected = %Feature{
        name: "Multiple scenarios",
        description: "",
        background: nil,
        scenarios: [
          %Scenario{
            name: "First scenario",
            line: 2,
            steps: [
              %Step{keyword: "Given", text: "something", line: 3, docstring: nil, datatable: nil},
              %Step{
                keyword: "When",
                text: "I do something",
                line: 4,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "Then",
                text: "I see something",
                line: 5,
                docstring: nil,
                datatable: nil
              }
            ]
          },
          %Scenario{
            name: "Second scenario",
            line: 7,
            steps: [
              %Step{
                keyword: "Given",
                text: "another thing",
                line: 8,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "When",
                text: "I do another thing",
                line: 9,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "Then",
                text: "I see another thing",
                line: 10,
                docstring: nil,
                datatable: nil
              }
            ]
          }
        ]
      }

      assert Gherkin.Parser.parse(gherkin) == expected
    end
  end

  describe "parse/1 with Scenario Outlines" do
    test "parses a simple scenario outline with one Examples block" do
      gherkin = """
      Feature: Calculator

      Scenario Outline: Adding numbers
        Given I have <a> and <b>
        When I add them
        Then the result is <sum>

        Examples:
          | a | b | sum |
          | 1 | 2 | 3   |
          | 5 | 3 | 8   |
      """

      result = Gherkin.Parser.parse(gherkin)

      assert result.name == "Calculator"
      assert length(result.scenarios) == 1

      [outline] = result.scenarios
      assert %ScenarioOutline{} = outline
      assert outline.name == "Adding numbers"
      assert length(outline.steps) == 3
      assert length(outline.examples) == 1

      [examples] = outline.examples
      assert examples.name == ""
      assert examples.table_header == ["a", "b", "sum"]
      assert examples.table_body == [["1", "2", "3"], ["5", "3", "8"]]
    end

    test "parses scenario outline with named Examples block" do
      gherkin = """
      Feature: Calculator

      Scenario Outline: Adding numbers
        Given I have <a> and <b>
        When I add them
        Then the result is <sum>

        Examples: positive numbers
          | a | b | sum |
          | 1 | 2 | 3   |
      """

      result = Gherkin.Parser.parse(gherkin)
      [outline] = result.scenarios
      [examples] = outline.examples

      assert examples.name == "positive numbers"
    end

    test "parses scenario outline with multiple Examples blocks" do
      gherkin = """
      Feature: Calculator

      Scenario Outline: Adding numbers
        Given I have <a> and <b>
        When I add them
        Then the result is <sum>

        Examples: positive
          | a | b | sum |
          | 1 | 2 | 3   |

        Examples: negative
          | a  | b  | sum |
          | -1 | -2 | -3  |
      """

      result = Gherkin.Parser.parse(gherkin)
      [outline] = result.scenarios

      assert length(outline.examples) == 2
      [ex1, ex2] = outline.examples

      assert ex1.name == "positive"
      assert ex1.table_body == [["1", "2", "3"]]

      assert ex2.name == "negative"
      assert ex2.table_body == [["-1", "-2", "-3"]]
    end

    test "parses scenario outline with tagged Examples blocks" do
      gherkin = """
      Feature: Calculator

      @outline-tag
      Scenario Outline: Adding numbers
        Given I have <a> and <b>
        Then the result is <sum>

        @positive
        Examples: positive
          | a | b | sum |
          | 1 | 2 | 3   |

        @negative @slow
        Examples: negative
          | a  | b  | sum |
          | -1 | -2 | -3  |
      """

      result = Gherkin.Parser.parse(gherkin)
      [outline] = result.scenarios

      assert outline.tags == ["outline-tag"]
      assert length(outline.examples) == 2

      [ex1, ex2] = outline.examples
      assert ex1.tags == ["positive"]
      assert ex2.tags == ["negative", "slow"]
    end

    test "parses feature with both scenarios and scenario outlines" do
      gherkin = """
      Feature: Mixed scenarios

      Scenario: Regular scenario
        Given something
        Then something else

      Scenario Outline: Outline scenario
        Given I have <value>
        Then I see <result>

        Examples:
          | value | result |
          | 1     | one    |
      """

      result = Gherkin.Parser.parse(gherkin)

      assert length(result.scenarios) == 2
      [scenario, outline] = result.scenarios

      assert %Scenario{} = scenario
      assert scenario.name == "Regular scenario"

      assert %ScenarioOutline{} = outline
      assert outline.name == "Outline scenario"
    end

    test "parses scenario outline with docstring containing placeholder" do
      gherkin = """
      Feature: Templates

      Scenario Outline: Greeting
        Given a template with content
          \"\"\"
          Hello <name>!
          \"\"\"
        Then the greeting is correct

        Examples:
          | name  |
          | Alice |
      """

      result = Gherkin.Parser.parse(gherkin)
      [outline] = result.scenarios
      [step | _] = outline.steps

      assert step.docstring == "Hello <name>!"
    end

    test "parses scenario outline with datatable containing placeholder" do
      gherkin = """
      Feature: Tables

      Scenario Outline: User data
        Given a user with attributes
          | name   | <name>   |
          | age    | <age>    |
        Then the user is valid

        Examples:
          | name  | age |
          | Alice | 30  |
      """

      result = Gherkin.Parser.parse(gherkin)
      [outline] = result.scenarios
      [step | _] = outline.steps

      assert step.datatable == [["name", "<name>"], ["age", "<age>"]]
    end
  end

  describe "parse/1 edge cases" do
    test "parses feature with description lines" do
      gherkin = """
      @async
      Feature: Async Feature Example
        This feature demonstrates running scenarios asynchronously
        Multiple description lines are allowed

      Scenario: First scenario
        Given a step
      """

      result = Gherkin.Parser.parse(gherkin)

      assert result.name == "Async Feature Example"
      assert result.tags == ["async"]
      assert length(result.scenarios) == 1
      assert hd(result.scenarios).name == "First scenario"
    end

    test "parses multiple scenario outlines with tags between them" do
      gherkin = """
      Feature: Multiple outlines

      Scenario Outline: First outline
        Given I have <a>

        Examples:
          | a |
          | 1 |

      @tagged
      Scenario Outline: Second outline
        Given I have <b>

        Examples:
          | b |
          | 2 |
      """

      result = Gherkin.Parser.parse(gherkin)

      assert length(result.scenarios) == 2
      [first, second] = result.scenarios

      assert first.name == "First outline"
      assert first.tags == []

      assert second.name == "Second outline"
      assert second.tags == ["tagged"]
    end

    test "parses scenario outline with multiple tagged Examples blocks" do
      gherkin = """
      Feature: Tagged examples

      @outline-tag
      Scenario Outline: Tagged example
        Given I have value <value>

        @smoke
        Examples: smoke tests
          | value |
          | foo   |

        @regression
        Examples: regression tests
          | value |
          | bar   |
      """

      result = Gherkin.Parser.parse(gherkin)

      assert length(result.scenarios) == 1
      [outline] = result.scenarios

      assert outline.name == "Tagged example"
      assert outline.tags == ["outline-tag"]
      assert length(outline.examples) == 2

      [smoke, regression] = outline.examples
      assert smoke.name == "smoke tests"
      assert smoke.tags == ["smoke"]
      assert regression.name == "regression tests"
      assert regression.tags == ["regression"]
    end

    test "parses feature with Windows-style \\r\\n line endings" do
      gherkin =
        "Feature: Windows Feature\r\n\r\nScenario: A scenario\r\n  Given a step\r\n  Then another step\r\n"

      result = Gherkin.Parser.parse(gherkin)

      assert result.name == "Windows Feature"
      assert length(result.scenarios) == 1
      [scenario] = result.scenarios
      assert scenario.name == "A scenario"
      assert length(scenario.steps) == 2
    end

    test "parses feature with Unicode in feature and scenario names" do
      gherkin = """
      Feature: Ünïcödé Féàtûrè

      Scenario: Scénàrïö with émojis and àccénts
        Given a step
      """

      result = Gherkin.Parser.parse(gherkin)

      assert result.name == "Ünïcödé Féàtûrè"
      [scenario] = result.scenarios
      assert scenario.name == "Scénàrïö with émojis and àccénts"
    end

    test "parses feature with very long step text" do
      long_text = String.duplicate("a", 500)

      gherkin = """
      Feature: Long steps

      Scenario: Long step text
        Given #{long_text}
      """

      result = Gherkin.Parser.parse(gherkin)

      [scenario] = result.scenarios
      [step] = scenario.steps
      assert step.text == long_text
    end

    test "all test feature files parse with expected scenario counts" do
      # This test ensures all feature files are fully parsed
      # If parsing fails silently, this test will catch it
      expected_counts = %{
        "test/features/advanced_features.feature" => 2,
        "test/features/async_example.feature" => 2,
        "test/features/custom_parameter_types.feature" => 2,
        "test/features/database_example.feature" => 2,
        "test/features/descriptions.feature" => 3,
        "test/features/error_reporting.feature" => 2,
        "test/features/feature_level_tags.feature" => 2,
        "test/features/hook_execution_order.feature" => 1,
        "test/features/parameters.feature" => 4,
        "test/features/regex_steps.feature" => 2,
        "test/features/return_values.feature" => 4,
        "test/features/rules.feature" => 2,
        "test/features/scenario_outline.feature" => 2,
        "test/features/shared_steps_integration.feature" => 2,
        "test/features/simple.feature" => 1,
        "test/features/tagged.feature" => 4
      }

      # Every live feature file must have an entry, so a new file can't
      # silently skip this check.
      assert Path.wildcard("test/features/**/*.feature") |> Enum.sort() ==
               expected_counts |> Map.keys() |> Enum.sort()

      for {file, expected_count} <- expected_counts do
        content = File.read!(file)
        result = Gherkin.Parser.parse(content)

        count =
          length(result.scenarios) +
            (result.rules |> Enum.map(&length(&1.scenarios)) |> Enum.sum())

        assert count == expected_count,
               "#{file}: expected #{expected_count} scenarios (incl. rules), got #{count}"
      end
    end
  end

  describe "parse/1 with comment lines" do
    test "comment line between Background and first Scenario is skipped" do
      gherkin = """
      Feature: Commented

        Background:
          Given a user exists

        # ===== Section Marker =====

        Scenario: First
          Given a thing
          Then it works

        Scenario: Second
          Given another thing
          Then it also works
      """

      result = Gherkin.Parser.parse(gherkin)

      assert length(result.scenarios) == 2
      assert Enum.map(result.scenarios, & &1.name) == ["First", "Second"]
    end

    test "comment line between scenarios is skipped" do
      gherkin = """
      Feature: Commented

      Scenario: First
        Given a thing

      # divider comment

      Scenario: Second
        Given another thing
      """

      result = Gherkin.Parser.parse(gherkin)

      assert Enum.map(result.scenarios, & &1.name) == ["First", "Second"]
    end

    test "comment line between steps is skipped" do
      gherkin = """
      Feature: Commented

      Scenario: Steps with comments
        Given step one
        # an explanatory comment
        When step two
        Then step three
      """

      result = Gherkin.Parser.parse(gherkin)

      [scenario] = result.scenarios
      assert Enum.map(scenario.steps, & &1.text) == ["step one", "step two", "step three"]
    end

    test "comment line before Feature keyword is skipped" do
      gherkin = """
      # top-of-file note
      Feature: Commented
        Scenario: x
          Given a thing
      """

      result = Gherkin.Parser.parse(gherkin)

      assert result.name == "Commented"
      assert length(result.scenarios) == 1
    end

    test "comment line before Examples block is skipped" do
      gherkin = """
      Feature: Commented Outline

      Scenario Outline: With comments
        Given I have <value>

        # values to try
        Examples:
          | value |
          | one   |
          | two   |
      """

      result = Gherkin.Parser.parse(gherkin)

      [outline] = result.scenarios
      [examples] = outline.examples
      assert examples.table_body == [["one"], ["two"]]
    end

    test "comment line between a tag and Scenario: keyword is skipped" do
      gherkin = """
      Feature: Commented

      Scenario: First
        Given a thing

      @wip
      # comment after tag
      Scenario: Second
        Given another thing
      """

      result = Gherkin.Parser.parse(gherkin)

      assert Enum.map(result.scenarios, & &1.name) == ["First", "Second"]
      [_first, second] = result.scenarios
      assert second.tags == ["wip"]
    end

    test "comment line between two tags on the same scenario is skipped" do
      gherkin = """
      Feature: Commented

      @wip
      # between tags
      @smoke
      Scenario: Double-tagged
        Given a thing
      """

      result = Gherkin.Parser.parse(gherkin)

      [scenario] = result.scenarios
      assert scenario.tags == ["wip", "smoke"]
    end

    test "raises when parser stops before consuming end of file" do
      # Trailing junk after the last scenario should not silently disappear.
      gherkin = """
      Feature: F

      Scenario: First
        Given a step

      this is not valid gherkin
      """

      assert_raise Gherkin.ParseError, ~r/Unexpected content/, fn ->
        Gherkin.Parser.parse(gherkin)
      end
    end

    test "comment line between an Examples tag and Examples: keyword is skipped" do
      gherkin = """
      Feature: Commented Outline

      Scenario Outline: With tagged examples
        Given I have <value>

        @smoke
        # tagged examples
        Examples:
          | value |
          | one   |
      """

      result = Gherkin.Parser.parse(gherkin)

      [outline] = result.scenarios
      [examples] = outline.examples
      assert examples.tags == ["smoke"]
      assert examples.table_body == [["one"]]
    end
  end
end
