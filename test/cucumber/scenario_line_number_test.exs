defmodule Cucumber.ScenarioLineNumberTest do
  use ExUnit.Case

  alias Cucumber.StepError
  alias Gherkin.Parser

  describe "scenario line number parsing" do
    test "parser captures scenario line numbers correctly" do
      gherkin = """
      Feature: Test Feature
        
        Scenario: First scenario
          Given a step
          When another step
          Then final step

        @tagged
        Scenario: Second scenario
          Given step one
          When step two
          Then step three
      """

      feature = Parser.parse(gherkin)

      assert length(feature.scenarios) == 2

      [first_scenario, second_scenario] = feature.scenarios

      # Line numbers are 0-based in the parser
      assert first_scenario.name == "First scenario"
      # Line 3 in editor (1-based)
      assert first_scenario.line == 2

      assert second_scenario.name == "Second scenario"
      # Line 9 in editor (1-based)
      assert second_scenario.line == 8
    end

    test "scenario line numbers work with backgrounds" do
      gherkin = """
      Feature: Test with Background

        Background:
          Given common setup

        Scenario: Scenario after background
          When I do something
          Then it works
      """

      feature = Parser.parse(gherkin)

      assert length(feature.scenarios) == 1
      scenario = hd(feature.scenarios)

      # Line 6 in editor
      assert scenario.line == 5
    end
  end

  describe "error message formatting with scenario lines" do
    test "missing step shows scenario line number when available" do
      step = %Gherkin.Step{
        keyword: "Given",
        text: "an undefined step",
        line: 10
      }

      # Simulate step history with context containing scenario line
      step_history = [
        {:passed, %Gherkin.Step{keyword: "Given", text: "setup"}, %{scenario_line: 5}}
      ]

      error =
        StepError.missing_step_definition(
          step,
          "test/features/example.feature",
          "My scenario",
          step_history
        )

      # Should show scenario line, not step line
      assert error.message =~ "test/features/example.feature:5"
      refute error.message =~ "test/features/example.feature:11"
    end

    test "missing step falls back to step line when scenario line not available" do
      step = %Gherkin.Step{
        keyword: "Given",
        text: "an undefined step",
        line: 10
      }

      error =
        StepError.missing_step_definition(
          step,
          "test/features/example.feature",
          "My scenario",
          []
        )

      # Should show step line + 1 (for 1-based line numbers)
      assert error.message =~ "test/features/example.feature:11"
    end

    test "failed step shows scenario line number when available" do
      step = %Gherkin.Step{
        keyword: "When",
        text: "this fails",
        line: 15
      }

      step_history = [
        {:failed, %Gherkin.Step{keyword: "When", text: "this fails"}, %{scenario_line: 12}}
      ]

      error =
        StepError.failed_step(
          step,
          "this fails",
          "Something went wrong",
          "test/features/failing.feature",
          "Failing scenario",
          step_history
        )

      assert error.message =~ "test/features/failing.feature:12"
    end
  end

  describe "runtime error formatting" do
    test "error includes scenario line from context" do
      step = %Gherkin.Step{
        keyword: "When",
        text: "something fails",
        line: 20
      }

      context = %{
        feature_file: "test/features/example.feature",
        scenario_name: "Error scenario",
        # This is what the compiler would set
        scenario_line: 15,
        step_history: [step]
      }

      # Format step history with context - this is internal to Runtime
      # so we'll simulate what it does
      step_history = [
        {:passed, step, context}
      ]

      # Create error with the formatted history
      error =
        StepError.failed_step(
          step,
          "something fails",
          "Test error",
          context.feature_file,
          context.scenario_name,
          step_history
        )

      # Should use scenario line from context
      assert error.message =~ "test/features/example.feature:15"
    end
  end
end
