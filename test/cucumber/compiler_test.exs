defmodule Cucumber.CompilerTest do
  use ExUnit.Case, async: true

  alias Gherkin.{Examples, Scenario, ScenarioOutline, Step}

  describe "expand_all_scenarios/1" do
    test "passes through regular scenarios unchanged" do
      scenario = %Scenario{
        name: "Regular scenario",
        steps: [%Step{keyword: "Given", text: "something", line: 1}],
        tags: ["smoke"],
        line: 5
      }

      result = Cucumber.Compiler.expand_all_scenarios([scenario])

      assert result == [scenario]
    end

    test "expands scenario outline into multiple scenarios" do
      outline = %ScenarioOutline{
        name: "Adding numbers",
        steps: [
          %Step{keyword: "Given", text: "I have <a> and <b>", line: 2},
          %Step{keyword: "Then", text: "the result is <sum>", line: 3}
        ],
        tags: ["math"],
        examples: [
          %Examples{
            name: "",
            tags: [],
            table_header: ["a", "b", "sum"],
            table_body: [["1", "2", "3"], ["5", "3", "8"]],
            line: 5
          }
        ],
        line: 1
      }

      result = Cucumber.Compiler.expand_all_scenarios([outline])

      assert length(result) == 2

      [first, second] = result

      assert %Scenario{} = first
      assert first.name == "Adding numbers (row 1)"
      assert first.tags == ["math"]
      assert hd(first.steps).text == "I have 1 and 2"
      assert List.last(first.steps).text == "the result is 3"

      assert %Scenario{} = second
      assert second.name == "Adding numbers (row 2)"
      assert hd(second.steps).text == "I have 5 and 3"
      assert List.last(second.steps).text == "the result is 8"
    end

    test "uses Examples name in test name when provided" do
      outline = %ScenarioOutline{
        name: "Test",
        steps: [%Step{keyword: "Given", text: "<val>", line: 1}],
        tags: [],
        examples: [
          %Examples{
            name: "positive numbers",
            tags: [],
            table_header: ["val"],
            table_body: [["1"]],
            line: 3
          }
        ],
        line: 1
      }

      [result] = Cucumber.Compiler.expand_all_scenarios([outline])

      assert result.name == "Test (positive numbers: row 1)"
    end

    test "combines outline tags with Examples tags" do
      outline = %ScenarioOutline{
        name: "Tagged",
        steps: [%Step{keyword: "Given", text: "<val>", line: 1}],
        tags: ["outline-tag"],
        examples: [
          %Examples{
            name: "",
            tags: ["example-tag", "smoke"],
            table_header: ["val"],
            table_body: [["1"]],
            line: 3
          }
        ],
        line: 1
      }

      [result] = Cucumber.Compiler.expand_all_scenarios([outline])

      assert "outline-tag" in result.tags
      assert "example-tag" in result.tags
      assert "smoke" in result.tags
    end

    test "substitutes placeholders in docstrings" do
      outline = %ScenarioOutline{
        name: "Docstring test",
        steps: [
          %Step{
            keyword: "Given",
            text: "a template",
            docstring: "Hello <name>!",
            line: 1
          }
        ],
        tags: [],
        examples: [
          %Examples{
            name: "",
            tags: [],
            table_header: ["name"],
            table_body: [["Alice"]],
            line: 4
          }
        ],
        line: 1
      }

      [result] = Cucumber.Compiler.expand_all_scenarios([outline])

      assert hd(result.steps).docstring == "Hello Alice!"
    end

    test "substitutes placeholders in datatables" do
      outline = %ScenarioOutline{
        name: "Datatable test",
        steps: [
          %Step{
            keyword: "Given",
            text: "a table",
            datatable: [["key", "<value>"], ["name", "<name>"]],
            line: 1
          }
        ],
        tags: [],
        examples: [
          %Examples{
            name: "",
            tags: [],
            table_header: ["value", "name"],
            table_body: [["123", "test"]],
            line: 4
          }
        ],
        line: 1
      }

      [result] = Cucumber.Compiler.expand_all_scenarios([outline])

      assert hd(result.steps).datatable == [["key", "123"], ["name", "test"]]
    end

    test "raises error when Scenario Outline has no Examples" do
      outline = %ScenarioOutline{
        name: "Missing examples",
        steps: [%Step{keyword: "Given", text: "something", line: 1}],
        tags: [],
        examples: [],
        line: 1
      }

      assert_raise RuntimeError,
                   ~r/Scenario Outline 'Missing examples' has no Examples section/,
                   fn ->
                     Cucumber.Compiler.expand_all_scenarios([outline])
                   end
    end

    test "expands multiple Examples blocks from same outline" do
      outline = %ScenarioOutline{
        name: "Multi-examples",
        steps: [%Step{keyword: "Given", text: "<val>", line: 1}],
        tags: [],
        examples: [
          %Examples{
            name: "first",
            tags: [],
            table_header: ["val"],
            table_body: [["a"]],
            line: 3
          },
          %Examples{
            name: "second",
            tags: [],
            table_header: ["val"],
            table_body: [["b"], ["c"]],
            line: 6
          }
        ],
        line: 1
      }

      result = Cucumber.Compiler.expand_all_scenarios([outline])

      assert length(result) == 3
      assert Enum.at(result, 0).name == "Multi-examples (first: row 1)"
      assert Enum.at(result, 1).name == "Multi-examples (second: row 1)"
      assert Enum.at(result, 2).name == "Multi-examples (second: row 2)"
    end
  end
end
