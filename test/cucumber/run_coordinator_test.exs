defmodule Cucumber.RunCoordinatorTest do
  # async: false — the coordinator is a named singleton and these tests
  # reset its run id.
  use ExUnit.Case, async: false

  alias Cucumber.RunCoordinator

  test "ensure_started starts the coordinator and returns a run id" do
    run_id = RunCoordinator.ensure_started()

    assert is_integer(run_id)
    assert RunCoordinator.run_id() == run_id
  end

  test "ensure_started on a running coordinator resets to a fresh run id" do
    first = RunCoordinator.ensure_started()
    second = RunCoordinator.ensure_started()

    assert second != first
    assert RunCoordinator.run_id() == second
  end
end
