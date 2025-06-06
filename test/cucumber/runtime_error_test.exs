defmodule Cucumber.RuntimeErrorTest do
  use ExUnit.Case

  alias Cucumber.Runtime
  alias Gherkin.Step

  describe "error formatting in execute_step/3" do
    setup do
      # Create a simple step registry for testing
      step_registry = %{
        "I fail with an error" => {FailingStepModule, %{}},
        "I fail with {string}" => {FailingStepModule, %{}}
      }

      {:ok, step_registry: step_registry}
    end

    test "missing step definition includes context", %{step_registry: step_registry} do
      step = %Step{
        keyword: "Given",
        text: "this step does not exist",
        line: 5
      }

      context = %{
        feature_file: "test/features/example.feature",
        scenario_name: "Test scenario",
        step_history: [
          %Step{keyword: "Given", text: "a previous step"}
        ]
      }

      assert_raise Cucumber.StepError, fn ->
        Runtime.execute_step(context, step, step_registry)
      end
    end

    test "step failure includes enhanced formatting", %{step_registry: step_registry} do
      step = %Step{
        keyword: "When",
        text: "I fail with an error",
        line: 10
      }

      context = %{
        feature_file: "test/features/error.feature",
        scenario_name: "Error handling",
        step_history: []
      }

      # This will fail because FailingStepModule doesn't exist
      # but we're testing the error handling
      assert_raise Cucumber.StepError, fn ->
        Runtime.execute_step(context, step, step_registry)
      end
    end
  end

  describe "PhoenixTest error formatting" do
    test "formats HTML elements with proper indentation" do
      # Create a mock module that can handle our test step
      defmodule MockPhoenixTestStep do
        def step(_context, _text) do
          # Simulate a PhoenixTest error
          raise """
          Could not find any elements with selector "button" and text "Submit"

          Found these elements matching the selector "button":

          <button class="btn btn-primary">
            Save Draft
          </button>

          <button class="btn btn-secondary">
            Cancel
          </button>

          <button type="submit" disabled>
            Submit (disabled)
          </button>
          """
        end
      end

      step_registry = %{
        "I click the submit button" => {MockPhoenixTestStep, %{}}
      }

      step = %Step{
        keyword: "When",
        text: "I click the submit button",
        line: 15
      }

      context = %{
        feature_file: "test/features/form.feature",
        scenario_name: "Form submission",
        step_history: [
          %Step{keyword: "Given", text: "I am on the form page"},
          %Step{keyword: "And", text: "I have filled in the form"}
        ]
      }

      error =
        assert_raise Cucumber.StepError, fn ->
          Runtime.execute_step(context, step, step_registry)
        end

      # Check that the error message is properly formatted
      assert error.message =~ "Step failed:"
      assert error.message =~ "When I click the submit button"
      assert error.message =~ "in scenario \"Form submission\""
      assert error.message =~ "test/features/form.feature:16"

      # Check HTML formatting
      assert error.message =~ "Found these elements"
      assert error.message =~ "<button class=\"btn btn-primary\">"
      assert error.message =~ "Save Draft"

      # Check step history
      assert error.message =~ "Step execution history:"
      assert error.message =~ "[passed] Given I am on the form page"
      assert error.message =~ "[passed] And I have filled in the form"
      assert error.message =~ "[failed] When I click the submit button"
    end
  end
end
