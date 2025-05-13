defmodule CucumberErrorHandlingTest do
  use ExUnit.Case, async: true

  # We're directly testing the error reporting functionality of our Cucumber implementation
  # without relying on actual Cucumber tests that are expected to fail

  describe "Cucumber.StepError" do
    test "missing_step_definition/4 creates a helpful error message" do
      # Create a mock step and generate an error
      step = %Gherkin.Step{
        keyword: "When",
        text: "I try to use a step with no definition",
        line: 5
      }

      error =
        Cucumber.StepError.missing_step_definition(
          step,
          "test/features/example.feature",
          "Missing Step Example",
          [{"passed", %Gherkin.Step{keyword: "Given", text: "initial setup", line: 3}}]
        )

      # Assert that the error message contains helpful information
      assert error.message =~ "No matching step definition found for step:"
      assert error.message =~ "When I try to use a step with no definition"
      assert error.message =~ "in scenario \"Missing Step Example\""
      # line + 1
      assert error.message =~ "test/features/example.feature:6"
      assert error.message =~ "defstep \"I try to use a step with no definition\", context do"

      # Check the struct fields
      assert error.step == step
      assert error.feature_file == "test/features/example.feature"
      assert error.scenario_name == "Missing Step Example"
      assert error.failure_reason == :missing_step_definition
      assert length(error.step_history) == 1
    end

    test "failed_step/6 creates a helpful error message for exceptions" do
      # Create a mock step and generate an error
      step = %Gherkin.Step{
        keyword: "When",
        text: "I execute a step that fails",
        line: 7
      }

      # Capture a real exception to use as the failure reason
      exception =
        try do
          raise "Test exception for error reporting"
        rescue
          e -> e
        end

      error =
        Cucumber.StepError.failed_step(
          step,
          # pattern
          "I execute a step that fails",
          exception,
          "test/features/example.feature",
          "Failing Step Example",
          [
            {"passed", %Gherkin.Step{keyword: "Given", text: "initial setup", line: 3}},
            {"failed", step}
          ]
        )

      # Assert that the error message contains helpful information
      assert error.message =~ "Step failed:"
      assert error.message =~ "When I execute a step that fails"
      assert error.message =~ "in scenario \"Failing Step Example\""
      # line + 1
      assert error.message =~ "test/features/example.feature:8"
      assert error.message =~ "matching pattern: \"I execute a step that fails\""
      assert error.message =~ "Test exception for error reporting"
      assert error.message =~ "Step execution history:"
      assert error.message =~ "[passed] Given initial setup"
      assert error.message =~ "[failed] When I execute a step that fails"

      # Check the struct fields
      assert error.step == step
      assert error.pattern == "I execute a step that fails"
      assert error.feature_file == "test/features/example.feature"
      assert error.scenario_name == "Failing Step Example"
      assert error.failure_reason == exception
      assert length(error.step_history) == 2
    end

    test "failed_step/6 creates a helpful error message for returned errors" do
      # Create a mock step and generate an error
      step = %Gherkin.Step{
        keyword: "Then",
        text: "the validation should succeed",
        line: 9
      }

      error =
        Cucumber.StepError.failed_step(
          step,
          # pattern
          "the validation should succeed",
          "Validation failed: invalid input data",
          "test/features/example.feature",
          "Error Return Example",
          [
            {"passed", %Gherkin.Step{keyword: "Given", text: "a form to fill", line: 3}},
            {"passed", %Gherkin.Step{keyword: "When", text: "I submit invalid data", line: 4}},
            {"failed", step}
          ]
        )

      # Assert that the error message contains helpful information
      assert error.message =~ "Step failed:"
      assert error.message =~ "Then the validation should succeed"
      assert error.message =~ "in scenario \"Error Return Example\""
      # line + 1
      assert error.message =~ "test/features/example.feature:10"
      assert error.message =~ "matching pattern: \"the validation should succeed\""
      assert error.message =~ "Validation failed: invalid input data"
      assert error.message =~ "Step execution history:"
      assert error.message =~ "[passed] Given a form to fill"
      assert error.message =~ "[passed] When I submit invalid data"
      assert error.message =~ "[failed] Then the validation should succeed"

      # Check the struct fields
      assert error.step == step
      assert error.pattern == "the validation should succeed"
      assert error.feature_file == "test/features/example.feature"
      assert error.scenario_name == "Error Return Example"
      assert error.failure_reason == "Validation failed: invalid input data"
      assert length(error.step_history) == 3
    end
  end

  # We can add future tests for other error reporting aspects here
end
