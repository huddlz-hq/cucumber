defmodule Cucumber.AmbiguousStepError do
  @moduledoc """
  Exception raised when a step's text matches more than one step definition.

  Cucumber cannot know which definition the author intended, so the scenario
  fails with this error listing every matching pattern and where each is
  defined. Ambiguity is a property of a concrete step text at runtime — two
  patterns may overlap for one input but not another — so this is detected
  during step resolution, not at load time.

  This is a distinct exception type (rather than a `Cucumber.StepError`) so
  downstream features can treat it specially — e.g. retry logic must never
  retry an ambiguous step, and Cucumber Messages report it as AMBIGUOUS
  rather than FAILED.
  """

  defexception [
    :message,
    :step,
    :matches,
    :feature_file,
    :scenario_name
  ]

  @type match :: {pattern_source :: String.t(), module(), metadata :: map()}

  @type t :: %__MODULE__{
          message: String.t(),
          step: Gherkin.Step.t() | nil,
          matches: [match()],
          feature_file: String.t() | nil,
          scenario_name: String.t() | nil
        }

  @doc """
  Builds the error for a step that matched several definitions.

  `matches` is a list of `{pattern_source, module, metadata}` tuples, where
  metadata carries the definition's `:file` and `:line`.
  """
  @spec new(Gherkin.Step.t(), [match()], String.t(), String.t()) :: t()
  def new(step, matches, feature_file, scenario_name) do
    location = "#{feature_file}:#{step.line + 1}"

    listing =
      Enum.map_join(matches, "\n", fn {pattern, module, metadata} ->
        "  * \"#{pattern}\" (#{inspect(module)} at #{Path.relative_to_cwd(metadata.file)}:#{metadata.line})"
      end)

    message = """
    Ambiguous step:

      #{step.keyword} #{step.text}

    in scenario "#{scenario_name}" (#{location})

    matches #{length(matches)} step definitions:

    #{listing}

    Remove or rephrase one of these definitions so only one matches.
    """

    %__MODULE__{
      message: message,
      step: step,
      matches: matches,
      feature_file: feature_file,
      scenario_name: scenario_name
    }
  end
end
