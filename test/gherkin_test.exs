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

    test "all test feature files parse with expected scenario counts" do
      # This test ensures all feature files are fully parsed
      # If parsing fails silently, this test will catch it
      expected_counts = %{
        "test/features/advanced_features.feature" => 2,
        "test/features/async_example.feature" => 2,
        "test/features/database_example.feature" => 2,
        "test/features/error_reporting.feature" => 2,
        "test/features/feature_level_tags.feature" => 2,
        "test/features/hook_execution_order.feature" => 1,
        "test/features/parameters.feature" => 1,
        "test/features/return_values.feature" => 4,
        "test/features/scenario_outline.feature" => 2,
        "test/features/shared_steps_integration.feature" => 2,
        "test/features/simple.feature" => 1,
        "test/features/tagged.feature" => 4
      }

      for {file, expected_count} <- expected_counts do
        content = File.read!(file)
        result = Gherkin.Parser.parse(content)

        assert length(result.scenarios) == expected_count,
               "#{file}: expected #{expected_count} scenarios, got #{length(result.scenarios)}"
      end
    end
  end
end
