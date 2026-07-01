defmodule Cucumber.Attachment do
  @moduledoc """
  An attachment recorded during a cucumber run via `Cucumber.attach/4`,
  `Cucumber.log/2`, or `Cucumber.link/2`.

  Attachments are attributed to the execution that recorded them:

    * `phase` - `:step`, `:before_scenario`, or `:after_scenario` (nil when
      recorded outside the scenario lifecycle, e.g. from a `before_all` hook)
    * `step_text`/`step_line` - set when `phase` is `:step`
    * `feature_file`/`scenario_name` - the owning scenario
    * `attempt` - the scenario's 1-based retry attempt (nil when recorded
      outside the scenario lifecycle)

  `body` holds text as-is (`encoding: :identity`) or Base64-encoded bytes
  (`encoding: :base64`), mirroring the Cucumber Messages attachment
  `contentEncoding` field.
  """

  defstruct [
    :body,
    :media_type,
    :encoding,
    :filename,
    :feature_file,
    :scenario_name,
    :step_text,
    :step_line,
    :phase,
    :attempt
  ]

  @type t :: %__MODULE__{
          body: String.t(),
          media_type: String.t(),
          encoding: :identity | :base64,
          filename: String.t() | nil,
          feature_file: String.t() | nil,
          scenario_name: String.t() | nil,
          step_text: String.t() | nil,
          step_line: non_neg_integer() | nil,
          phase: :step | :before_scenario | :after_scenario | nil,
          attempt: pos_integer() | nil
        }
end
