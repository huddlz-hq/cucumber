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

  defmodule BeforeAllProbe do
    def increment(context) do
      count = Agent.get_and_update(__MODULE__.Counter, &{&1 + 1, &1 + 1})
      {:ok, Map.put(context, :count, count)}
    end
  end

  describe "before_all_context/1" do
    test "executes before_all hooks once and caches the merged context" do
      {:ok, _} = Agent.start(fn -> 0 end, name: BeforeAllProbe.Counter)
      on_exit(fn -> Agent.stop(BeforeAllProbe.Counter) end)

      RunCoordinator.ensure_started()
      hooks = [{:before_all, nil, nil, {BeforeAllProbe, :increment}}]

      assert {:ok, %{count: 1}} = RunCoordinator.before_all_context(hooks)
      # Second call returns the cached result without re-running the hook
      assert {:ok, %{count: 1}} = RunCoordinator.before_all_context(hooks)
      assert Agent.get(BeforeAllProbe.Counter, & &1) == 1

      # A reset clears the cache: the hook runs again for the new run
      RunCoordinator.ensure_started()
      assert {:ok, %{count: 2}} = RunCoordinator.before_all_context(hooks)
    end

    test "returns {:ok, %{}} without hooks and without a coordinator" do
      assert {:ok, %{}} = RunCoordinator.before_all_context([])
    end
  end

  describe "run_after_all/1" do
    defmodule AfterAllProbe do
      # run_after_all executes hooks in the calling process — the test
      # process here — so self() is the test pid
      def record(context) do
        send(self(), {:after_all_ran, context.suite_result})
        :ok
      end

      def explode(_context), do: raise("cleanup went wrong")
    end

    test "claims registered after_all hooks exactly once" do
      RunCoordinator.ensure_started()
      RunCoordinator.register_after_all([{:after_all, nil, nil, {AfterAllProbe, :record}}])

      suite_result = %{total: 5, failures: 0}
      assert :ok = RunCoordinator.run_after_all(suite_result)
      assert_receive {:after_all_ran, ^suite_result}

      # Already claimed: nothing runs the second time
      assert :ok = RunCoordinator.run_after_all(suite_result)
      refute_receive {:after_all_ran, _}
    end

    test "a raising after_all hook fails the run with its own error" do
      RunCoordinator.ensure_started()
      RunCoordinator.register_after_all([{:after_all, nil, nil, {AfterAllProbe, :explode}}])

      assert_raise RuntimeError, "cleanup went wrong", fn ->
        RunCoordinator.run_after_all(%{total: 0, failures: 0})
      end
    end
  end
end
