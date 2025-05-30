defmodule Cucumber.StepError do
  @moduledoc """
  Exception raised when a step in a Cucumber scenario fails.

  This module provides detailed error reporting for two main failure cases:

  1. A step has no matching step definition
  2. A step's implementation raises an error or returns `{:error, reason}`

  The error messages include helpful context like:
  - The failing step text and location
  - The scenario name and feature file
  - A history of previously executed steps
  - Suggestions for implementing missing steps
  """

  defexception [
    :message,
    :step,
    :pattern,
    :feature_file,
    :scenario_name,
    :failure_reason,
    :step_history
  ]

  @type t :: %__MODULE__{
          message: String.t(),
          step: Gherkin.Step.t() | nil,
          pattern: String.t() | nil,
          feature_file: String.t() | nil,
          scenario_name: String.t() | nil,
          failure_reason: term(),
          step_history: list()
        }

  @doc """
  Creates a new step error for a missing step definition.

  When a step in a feature file doesn't match any step definition, this function
  creates a helpful error message that includes a suggestion for implementing
  the missing step.

  ## Parameters

  * `step` - The `Gherkin.Step` struct that has no matching definition
  * `feature_file` - The path to the feature file containing the step
  * `scenario_name` - The name of the scenario containing the step
  * `step_history` - A list of previously executed steps with their status

  ## Returns

  Returns a `Cucumber.StepError` struct with a formatted error message and context.

  ## Examples

  The error message will include a suggested implementation like:

      step "I click the submit button", context do
        # Your step implementation here
        context
      end
  """
  def missing_step_definition(step, feature_file, scenario_name, step_history \\ []) do
    message = """
    No matching step definition found for step:

      #{step.keyword} #{step.text}

    in scenario "#{scenario_name}" (#{feature_file}:#{step.line + 1})

    Please define this step with:

    step "#{format_step_for_suggestion(step.text)}", context do
      # Your step implementation here
      context
    end
    """

    %__MODULE__{
      message: message,
      step: step,
      feature_file: feature_file,
      scenario_name: scenario_name,
      failure_reason: :missing_step_definition,
      step_history: step_history
    }
  end

  @doc """
  Creates a new step error for a step execution failure.

  When a step implementation raises an exception or returns `{:error, reason}`,
  this function creates a detailed error message with context about the failure.

  ## Parameters

  * `step` - The `Gherkin.Step` struct that failed during execution
  * `pattern` - The step pattern that matched the step
  * `failure_reason` - The exception or error reason
  * `feature_file` - The path to the feature file containing the step
  * `scenario_name` - The name of the scenario containing the step
  * `step_history` - A list of previously executed steps with their status

  ## Returns

  Returns a `Cucumber.StepError` struct with a formatted error message and context.

  ## Examples

  The error message will include details like:

      Step failed:

        Then the result should be 10

      in scenario "Basic math" (test/features/calculator.feature:12)
      matching pattern: "the result should be {int}"

      Expected 10 but got 9

      Step execution history:
        [passed] Given I have entered 5 into the calculator
        [passed] And I have entered 4 into the calculator
        [passed] When I press add
        [failed] Then the result should be 10
  """
  def failed_step(step, pattern, failure_reason, feature_file, scenario_name, step_history \\ []) do
    message = """
    Step failed:

      #{step.keyword} #{step.text}

    in scenario "#{scenario_name}" (#{feature_file}:#{step.line + 1})
    matching pattern: "#{pattern}"

    #{format_failure_reason(failure_reason)}
    """

    formatted_message =
      if step_history && length(step_history) > 0 do
        message <> "\n" <> format_step_history(step_history)
      else
        message
      end

    %__MODULE__{
      message: formatted_message,
      step: step,
      pattern: pattern,
      feature_file: feature_file,
      scenario_name: scenario_name,
      failure_reason: failure_reason,
      step_history: step_history
    }
  end

  # Helper functions for formatting

  defp format_step_for_suggestion(text) do
    # Simple conversion to use Cucumber Expression placeholders
    # Replace quoted strings with {string}, numbers with {int} or {float}
    text
    |> String.replace(~r/"([^"]*)"/, "{string}")
    |> String.replace(~r/\b(\d+\.\d+)\b/, "{float}")
    |> String.replace(~r/\b(\d+)\b/, "{int}")
  end

  defp format_failure_reason(reason) when is_binary(reason), do: reason
  defp format_failure_reason(%{message: message}), do: message

  defp format_failure_reason(%{__exception__: true} = exception),
    do: Exception.message(exception)

  defp format_failure_reason(reason), do: inspect(reason, pretty: true)

  defp format_step_history(step_history) do
    """
    Step execution history:
    #{Enum.map_join(step_history, "\n", fn {status, step} -> "  [#{status}] #{step.keyword} #{step.text}" end)}
    """
  end
end
