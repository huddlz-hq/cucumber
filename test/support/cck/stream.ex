defmodule Cucumber.CckStream do
  @moduledoc """
  Integrity assertions on complete, raw Messages streams before approval scrubbing.
  Attempts are tracked independently so parallel scenarios may interleave.
  """
  import ExUnit.Assertions

  def assert_valid(envelopes) do
    assert [%{"meta" => %{"protocolVersion" => "33.0.2"}} | _] = envelopes

    state = %{ids: %{}, run: nil, cases: %{}, attempts: %{}, hooks: MapSet.new()}

    state =
      envelopes
      |> Enum.with_index()
      |> Enum.reduce(state, fn {envelope, index}, state ->
        Cucumber.CckSchema.assert_valid(envelope)
        [{type, payload}] = Map.to_list(envelope)
        assert type != "meta" or index == 0, "meta must occur once, first"
        assert state.run != :finished, "message after testRunFinished"
        state = references(payload, type, state)
        lifecycle(type, payload, state)
      end)

    assert state.run == :finished, "missing testRunFinished"
    :ok
  end

  defp references(payload, type, state) do
    definitions = collect_ids(payload, type)

    ids =
      Enum.reduce(definitions, state.ids, fn {id, kind}, ids ->
        refute Map.has_key?(ids, id), "duplicate id #{id}"
        Map.put(ids, id, kind)
      end)

    # A definition must be in an earlier envelope; nested definitions in one
    # AST/testCase are registered together, without relying on map key order.
    check_references(payload, state.ids)

    %{state | ids: ids}
  end

  @reference_types %{
    "astNodeId" => "gherkinDocument",
    "astNodeIds" => "gherkinDocument",
    "pickleId" => "pickle",
    "pickleStepId" => "pickleStep",
    "stepDefinitionIds" => "stepDefinition",
    "hookId" => "hook",
    "testCaseId" => "testCase",
    "testStepId" => "testStep",
    "testCaseStartedId" => "testCaseStarted",
    "testRunStartedId" => "testRunStarted",
    "testRunHookStartedId" => "testRunHookStarted"
  }

  defp check_references(map, ids) when is_map(map) do
    for {key, value} <- map do
      if String.ends_with?(key, "Id") or String.ends_with?(key, "Ids") do
        check_reference(key, value, ids)
      else
        check_references(value, ids)
      end
    end
  end

  defp check_references(list, ids) when is_list(list),
    do: Enum.each(list, &check_references(&1, ids))

  defp check_references(_value, _ids), do: :ok

  defp check_reference(key, value, ids) do
    expected = Map.fetch!(@reference_types, key)

    for id <- List.wrap(value) do
      assert Map.has_key?(ids, id), "undefined or forward reference #{id}"
      assert ids[id] == expected, "#{key}: reference to wrong message type"
    end
  end

  defp collect_ids(map, type) when is_map(map) do
    Enum.flat_map(map, fn
      {"id", id} -> [{id, type}]
      {"steps", steps} when type == "pickle" -> collect_ids(steps, "pickleStep")
      {"testSteps", steps} when type == "testCase" -> collect_ids(steps, "testStep")
      {_key, value} -> collect_ids(value, type)
    end)
  end

  defp collect_ids(list, type) when is_list(list), do: Enum.flat_map(list, &collect_ids(&1, type))
  defp collect_ids(_value, _type), do: []

  defp lifecycle("testRunStarted", payload, state) do
    assert state.run == nil, "duplicate testRunStarted"
    %{state | run: payload["id"]}
  end

  defp lifecycle("testCase", payload, state) do
    steps = Enum.map(payload["testSteps"], & &1["id"])
    %{state | cases: Map.put(state.cases, payload["id"], steps)}
  end

  defp lifecycle("testCaseStarted", payload, state) do
    running!(state)
    steps = Map.fetch!(state.cases, payload["testCaseId"])
    attempt = %{remaining: steps, active: nil}
    %{state | attempts: Map.put(state.attempts, payload["id"], attempt)}
  end

  defp lifecycle("testStepStarted", payload, state) do
    update_attempt(state, payload, fn attempt ->
      assert attempt.active == nil, "overlapping steps within an attempt"
      assert [next | _] = attempt.remaining, "step started after all steps finished"
      assert next == payload["testStepId"], "step started out of testCase order"
      %{attempt | active: next}
    end)
  end

  defp lifecycle("testStepFinished", payload, state) do
    update_attempt(state, payload, fn attempt ->
      assert attempt.active == payload["testStepId"], "step finished without matching start"
      %{attempt | active: nil, remaining: tl(attempt.remaining)}
    end)
  end

  defp lifecycle("testCaseFinished", payload, state) do
    state =
      update_attempt(state, payload, fn attempt ->
        assert attempt.active == nil and attempt.remaining == [], "case finished before its steps"
        attempt
      end)

    %{state | attempts: Map.delete(state.attempts, payload["testCaseStartedId"])}
  end

  defp lifecycle("attachment", payload, state) do
    update_attempt(state, payload, fn attempt ->
      assert is_binary(attempt.active) and attempt.active == payload["testStepId"],
             "attachment outside its active step"

      attempt
    end)
  end

  defp lifecycle("testRunHookStarted", payload, state) do
    running!(state)
    %{state | hooks: MapSet.put(state.hooks, payload["id"])}
  end

  defp lifecycle("testRunHookFinished", payload, state) do
    id = payload["testRunHookStartedId"]
    assert MapSet.member?(state.hooks, id), "run hook finished without matching start"
    %{state | hooks: MapSet.delete(state.hooks, id)}
  end

  defp lifecycle("testRunFinished", _payload, state) do
    running!(state)

    assert state.attempts == %{} and MapSet.size(state.hooks) == 0,
           "run finished with active work"

    %{state | run: :finished}
  end

  defp lifecycle(_type, _payload, state), do: state

  defp update_attempt(state, payload, fun) do
    running!(state)
    id = payload["testCaseStartedId"]
    assert Map.has_key?(state.attempts, id), "event outside active test case attempt"
    %{state | attempts: Map.update!(state.attempts, id, fun)}
  end

  defp running!(state) do
    assert is_binary(state.run), "event outside active test run"
  end
end
