defmodule Cucumber.RunCoordinatorTest do
  # async: false — the coordinator is a named singleton and these tests
  # reset its run id.
  use ExUnit.Case, async: false

  alias Cucumber.RunCoordinator

  setup do
    Cucumber.BehaviorCase.isolate_coordinator()
  end

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

  test "teardown releases every joined compilation and reused slots reject stale handles" do
    registry = Cucumber.StepRegistry.new([])
    first = RunCoordinator.register_compilation(registry, [])
    second = RunCoordinator.register_compilation(registry, [])
    assert first != second
    assert Cucumber.CompiledRuntime.fetch!(first) == Cucumber.CompiledRuntime.fetch!(second)

    RunCoordinator.end_run()

    for {slot, _generation} <- [first, second] do
      assert :persistent_term.get(slot, :absent) == :absent
    end

    RunCoordinator.start_or_join()
    fresh = RunCoordinator.register_compilation(registry, [])
    assert %{step_registry: ^registry} = Cucumber.CompiledRuntime.fetch!(fresh)

    for stale <- [first, second] do
      assert_raise RuntimeError, ~r/compile_features!/, fn ->
        Cucumber.CompiledRuntime.fetch!(stale)
      end
    end
  end

  defmodule BeforeAllProbe do
    def increment(context) do
      count = Agent.get_and_update(__MODULE__.Counter, &{&1 + 1, &1 + 1})
      {:ok, Map.put(context, :count, count)}
    end

    # The first time it runs, the run is reset (a new `compile_features!`,
    # e.g. under `mix test.watch`) while the hook is still executing, so
    # its result reaches the coordinator after the reset
    def reset_run_mid_hook(context) do
      {:ok, context} = increment(context)
      if context.count == 1, do: Cucumber.RunCoordinator.ensure_started()
      {:ok, context}
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

    test "a result that arrives after the run was reset does not settle the new run" do
      {:ok, _} = Agent.start(fn -> 0 end, name: BeforeAllProbe.Counter)
      on_exit(fn -> Agent.stop(BeforeAllProbe.Counter) end)

      RunCoordinator.ensure_started()
      hooks = [{:before_all, nil, nil, {BeforeAllProbe, :reset_run_mid_hook}}]

      # The caller from the old run still gets its own hooks' result
      assert {:ok, %{count: 1}} = RunCoordinator.before_all_context(hooks)

      # The new run has not run its hooks: the stale result was ignored, so
      # its first caller runs them afresh
      assert {:ok, %{count: 2}} = RunCoordinator.before_all_context(hooks)
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

      def setup(_context), do: %{resource: make_ref()}
      def fail_setup(_context), do: {:error, "setup failed"}

      def release(context) do
        send(self(), {:released, context.resource})
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

    test "a failed setup preserves its resources for cleanup and leaves other groups runnable" do
      RunCoordinator.ensure_started()
      setup = {:before_all, nil, nil, {AfterAllProbe, :setup}}
      fail = {:before_all, nil, nil, {AfterAllProbe, :fail_setup}}
      teardown = {:after_all, nil, nil, {AfterAllProbe, :release}}
      failed = [setup, fail, teardown]
      passed = [setup, teardown]

      for group <- [failed, passed, passed], do: RunCoordinator.register_after_all(group)
      assert {:error, error} = RunCoordinator.before_all_context(failed)
      assert {:error, ^error} = RunCoordinator.before_all_context(failed)
      assert {:ok, %{resource: resource}} = RunCoordinator.before_all_context(passed)
      assert {:ok, %{resource: ^resource}} = RunCoordinator.before_all_context(passed)

      assert :ok = RunCoordinator.run_after_all(%{total: 2, failures: 1})
      assert_receive {:released, ^resource}
      assert_receive {:released, other}
      refute resource == other
      refute_received {:released, _}
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
