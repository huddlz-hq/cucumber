defmodule Cucumber.StepErrorTest do
  use ExUnit.Case

  alias Cucumber.StepError
  alias Gherkin.Step

  describe "missing_step_definition/4" do
    test "creates error with helpful message for missing step" do
      step = %Step{
        keyword: "Given",
        text: "I have 5 apples",
        line: 10
      }

      error = StepError.missing_step_definition(
        step,
        "test/features/fruit.feature",
        "Counting fruit",
        []
      )

      assert error.step == step
      assert error.feature_file == "test/features/fruit.feature"
      assert error.scenario_name == "Counting fruit"
      assert error.failure_reason == :missing_step_definition

      assert error.message =~ "No matching step definition found"
      assert error.message =~ "Given I have 5 apples"
      assert error.message =~ "in scenario \"Counting fruit\""
      assert error.message =~ "test/features/fruit.feature:11"
      assert error.message =~ "step \"I have {int} apples\", context do"
    end

    test "converts quoted strings to {string} in suggestions" do
      step = %Step{
        keyword: "When",
        text: ~s(I enter "john@example.com" as my email),
        line: 5
      }

      error = StepError.missing_step_definition(step, "test.feature", "Login", [])

      assert error.message =~ "step \"I enter {string} as my email\", context do"
    end

    test "converts numbers to {int} and {float} in suggestions" do
      step = %Step{
        keyword: "Then",
        text: "the total should be 42.5 with 3 items",
        line: 8
      }

      error = StepError.missing_step_definition(step, "test.feature", "Math", [])

      assert error.message =~ "step \"the total should be {float} with {int} items\", context do"
    end
  end

  describe "failed_step/6" do
    test "creates error with step execution details" do
      step = %Step{
        keyword: "Then",
        text: "I should see the dashboard",
        line: 15
      }

      error = StepError.failed_step(
        step,
        "I should see the dashboard",
        "Element not found",
        "test/features/auth.feature",
        "User login",
        []
      )

      assert error.step == step
      assert error.pattern == "I should see the dashboard"
      assert error.feature_file == "test/features/auth.feature"
      assert error.scenario_name == "User login"

      assert error.message =~ "Step failed:"
      assert error.message =~ "Then I should see the dashboard"
      assert error.message =~ "in scenario \"User login\""
      assert error.message =~ "test/features/auth.feature:16"
      assert error.message =~ "matching pattern: \"I should see the dashboard\""
      assert error.message =~ "Element not found"
    end

    test "includes step history when provided" do
      current_step = %Step{
        keyword: "Then",
        text: "I should be logged in",
        line: 20
      }

      step_history = [
        {:passed, %Step{keyword: "Given", text: "I am on the login page"}},
        {:passed, %Step{keyword: "When", text: "I enter valid credentials"}},
        {:failed, current_step}
      ]

      error = StepError.failed_step(
        current_step,
        "I should be logged in",
        "Unexpected redirect",
        "test.feature",
        "Login flow",
        step_history
      )

      assert error.message =~ "Step execution history:"
      assert error.message =~ "[passed] Given I am on the login page"
      assert error.message =~ "[passed] When I enter valid credentials"
      assert error.message =~ "[failed] Then I should be logged in"
    end

    test "formats exception messages properly" do
      step = %Step{keyword: "When", text: "I click submit", line: 5}

      exception = %RuntimeError{message: "Button not found"}

      error = StepError.failed_step(
        step,
        "I click submit",
        exception,
        "test.feature",
        "Form submission",
        []
      )

      assert error.message =~ "Button not found"
    end

    test "formats binary reasons" do
      step = %Step{keyword: "Then", text: "it works", line: 1}

      error = StepError.failed_step(
        step,
        "it works",
        "Simple failure message",
        "test.feature",
        "Test",
        []
      )

      assert error.message =~ "Simple failure message"
    end

    test "formats multi-line reasons preserving structure" do
      step = %Step{keyword: "Then", text: "I see elements", line: 1}

      multi_line_reason = """
      Could not find element

      Expected:
        <button>Submit</button>

      Found:
        <button>Cancel</button>
      """

      error = StepError.failed_step(
        step,
        "I see elements",
        multi_line_reason,
        "test.feature",
        "UI test",
        []
      )

      assert error.message =~ "Could not find element"
      assert error.message =~ "Expected:"
      assert error.message =~ "<button>Submit</button>"
    end
  end
end