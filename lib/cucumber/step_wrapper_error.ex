defmodule Cucumber.StepWrapperError do
  @moduledoc """
  Fails a step whose configured `step_wrapper` broke its contract: it
  didn't call `run` exactly once in its own process, or it raised before
  `run` or after `run` returned (see "Step Wrapper" in the Hooks guide).

  `:cause` holds the wrapper's own raise, if any: the exception, or
  `{kind, reason}` for a throw or exit. `:contract` is `true` for a
  contract break, which repeats on every attempt, so scenarios failing
  with it are never retried. A raise, exit or throw from the wrapper is
  retried like its cause would be.
  """

  defexception [:message, :cause, contract: false]
end
