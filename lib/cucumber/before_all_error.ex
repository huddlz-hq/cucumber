defmodule Cucumber.BeforeAllError do
  @moduledoc """
  Raised in every scenario when the run's `before_all` hooks failed.

  The `before_all` result is computed once and cached for the whole run
  (see `Cucumber.RunCoordinator`), so this failure is deterministic —
  scenarios failing with it are never retried.
  """

  defexception [:message]
end
