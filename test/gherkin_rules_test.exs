defmodule GherkinRulesTest do
  use ExUnit.Case, async: true

  alias Gherkin.Parser

  describe "Rule parsing" do
    test "a rule groups its scenarios with name, description, and tags" do
      feature =
        Parser.parse("""
        Feature: F

          @rule-tag
          Rule: A sale cannot happen without money
            The rule description.

            Scenario: no money
              Given no money

            Scenario: enough money
              Given enough money
        """)

      assert feature.scenarios == []
      assert [rule] = feature.rules
      assert rule.name == "A sale cannot happen without money"
      assert rule.description == "The rule description."
      assert rule.tags == ["rule-tag"]
      assert Enum.map(rule.scenarios, & &1.name) == ["no money", "enough money"]
      assert rule.line == 3
    end

    test "Example: is a synonym for Scenario:, and Examples: still parses tables" do
      feature =
        Parser.parse("""
        Feature: F

          Rule: examples synonym
            Example: written as Example
              Given a step

          Scenario Outline: outline still works
            Given <thing>

            Examples:
              | thing |
              | a     |
        """)

      # Note: the bare outline precedes the rule in source order? It does not —
      # scenarios after a Rule belong to the rule. This source puts the outline
      # AFTER the rule, so it nests inside it.
      assert [rule] = feature.rules
      assert [example, outline] = rule.scenarios
      assert %Gherkin.Scenario{name: "written as Example"} = example
      assert %Gherkin.ScenarioOutline{name: "outline still works"} = outline
      assert [%Gherkin.Examples{table_body: [["a"]]}] = outline.examples
    end

    test "rules can have their own background" do
      feature =
        Parser.parse("""
        Feature: F

          Background:
            Given a feature-level order

          Rule: with background
            Background:
              Given a rule-level order

            Example: one
              When an action
        """)

      assert [%Gherkin.Step{text: "a feature-level order"}] = feature.background.steps
      assert [rule] = feature.rules
      assert [%Gherkin.Step{text: "a rule-level order"}] = rule.background.steps
    end

    test "a rule may have an empty name (CCK rules-backgrounds shape)" do
      feature =
        Parser.parse("""
        Feature: F

          Rule:
            Example: anonymous rule scenario
              Given a step
        """)

      assert [rule] = feature.rules
      assert rule.name == ""
      assert [%Gherkin.Scenario{name: "anonymous rule scenario"}] = rule.scenarios
    end

    test "bare scenarios and rules coexist; scenarios after a rule belong to it" do
      feature =
        Parser.parse("""
        Feature: F

          Scenario: feature-level scenario
            Given a step

          Rule: first rule
            Scenario: inside first
              Given a step

          Rule: second rule
            Scenario: inside second
              Given a step

            Scenario: also inside second
              Given a step
        """)

      assert [%Gherkin.Scenario{name: "feature-level scenario"}] = feature.scenarios
      assert [first, second] = feature.rules
      assert Enum.map(first.scenarios, & &1.name) == ["inside first"]
      assert Enum.map(second.scenarios, & &1.name) == ["inside second", "also inside second"]
    end

    test "comments between rule scenarios are skipped (CCK rules shape)" do
      feature =
        Parser.parse("""
        Feature: F

          Rule: with comments
            # Unhappy path
            Example: one
              Given a step

            # Happy path
            Example: two
              Given a step
        """)

      assert [rule] = feature.rules
      assert length(rule.scenarios) == 2
    end

    test "the CCK rules fixtures parse with expected structure" do
      rules =
        "test/fixtures/cck/rules/rules.feature"
        |> File.read!()
        |> Parser.parse()

      assert length(rules.rules) == 2
      assert [r1, r2] = rules.rules
      assert length(r1.scenarios) == 2
      assert length(r2.scenarios) == 1
      assert r2.tags == ["some-tag"]

      backgrounds =
        "test/fixtures/cck/rules-backgrounds/rules-backgrounds.feature"
        |> File.read!()
        |> Parser.parse()

      assert backgrounds.background
      assert [rule] = backgrounds.rules
      assert length(rule.background.steps) == 2
      assert length(rule.scenarios) == 2

      failedish =
        "test/fixtures/cck/failedish-combinations/failedish-combinations.feature"
        |> File.read!()
        |> Parser.parse()

      assert length(failedish.rules) == 3
      assert Enum.map(failedish.rules, &length(&1.scenarios)) == [4, 4, 1]
    end
  end
end
