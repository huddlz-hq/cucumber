defmodule Cucumber.StepError do
  @moduledoc """
  Exception raised when a step in a Cucumber scenario fails.
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
  """
  def missing_step_definition(step, feature_file, scenario_name, step_history \\ []) do
    message = """
    No matching step definition found for step:

      #{step.keyword} #{step.text}

    in scenario "#{scenario_name}" (#{feature_file}:#{step.line + 1})

    Please define this step with:

    defstep "#{format_step_for_suggestion(step.text)}", context do
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
