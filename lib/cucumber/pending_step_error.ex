defmodule Cucumber.PendingStepError do
  @moduledoc """
  Exception raised when a step (or before hook) signals it is not yet
  implemented by returning `:pending` or `{:pending, message}`.

  Pending follows the Cucumber semantics: the remaining steps in the
  scenario are skipped, after hooks still run, and the scenario as a whole
  fails with this error — pending work is a failure, unlike `:skipped`
  which is deliberate and non-failing.

  This is a distinct exception type (rather than a `Cucumber.StepError`) so
  downstream features can treat it specially — e.g. retry logic must never
  retry a pending step, and Cucumber Messages report it as PENDING rather
  than FAILED.
  """

  defexception [
    :message,
    :step,
    :reason,
    :feature_file,
    :scenario_name
  ]

  @type t :: %__MODULE__{
          message: String.t(),
          step: Gherkin.Step.t() | nil,
          reason: String.t() | nil,
          feature_file: String.t() | nil,
          scenario_name: String.t() | nil
        }

  @doc """
  Builds the error for a pending signal.

  `source` is `{:step, step}` for a pending step definition, or
  `:before_hook` when a before hook returned the pending signal. `reason`
  is the optional message from `{:pending, message}`.
  """
  @spec new({:step, Gherkin.Step.t()} | :before_hook, String.t() | nil, String.t(), String.t()) ::
          t()
  def new(source, reason, feature_file, scenario_name) do
    {step, header} =
      case source do
        {:step, step} ->
          {step,
           "Pending step:\n\n" <>
             "  #{step.keyword} #{step.text}\n\n" <>
             "in scenario \"#{scenario_name}\" (#{feature_file}:#{step.line + 1})"}

        :before_hook ->
          {nil,
           "Pending scenario:\n\n" <>
             "a before hook signaled pending in scenario \"#{scenario_name}\" (#{feature_file})"}
      end

    message = """
    #{header}

    #{reason_line(reason)}Remaining steps were skipped; implement the pending step to make the scenario pass.
    """

    %__MODULE__{
      message: message,
      step: step,
      reason: reason,
      feature_file: feature_file,
      scenario_name: scenario_name
    }
  end

  defp reason_line(nil), do: ""
  defp reason_line(reason), do: "Reason: #{reason}\n\n"
end
