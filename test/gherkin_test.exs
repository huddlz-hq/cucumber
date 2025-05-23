defmodule Gherkin.ParserTest do
  use ExUnit.Case, async: true

  alias Gherkin.{Background, Feature, Scenario, Step}

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
              line: 1,
              docstring: nil,
              datatable: nil
            }
          ]
        },
        scenarios: [
          %Scenario{
            name: "User joins an event",
            steps: [
              %Step{
                keyword: "Given",
                text: "an event titled \"Tech Gathering\"",
                line: 1,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "When",
                text: "I visit \"/\"",
                line: 2,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "Then",
                text: "I should see the event",
                line: 3,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "When",
                text: "I click \"join\" on the first event",
                line: 4,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "Then",
                text: "I should see \"joined event\"",
                line: 5,
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
            steps: [
              %Step{keyword: "Given", text: "something", line: 1, docstring: nil, datatable: nil},
              %Step{
                keyword: "When",
                text: "I do something",
                line: 2,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "Then",
                text: "I see something",
                line: 3,
                docstring: nil,
                datatable: nil
              }
            ]
          },
          %Scenario{
            name: "Second scenario",
            steps: [
              %Step{
                keyword: "Given",
                text: "another thing",
                line: 5,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "When",
                text: "I do another thing",
                line: 6,
                docstring: nil,
                datatable: nil
              },
              %Step{
                keyword: "Then",
                text: "I see another thing",
                line: 7,
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
end
