defmodule Cucumber.CckValidationTest do
  use ExUnit.Case, async: true

  alias Cucumber.CckSchema
  alias Cucumber.CckStream

  defp minimal do
    "test/fixtures/cck/minimal/minimal.ndjson"
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp change(stream, type, fun) do
    Enum.map(stream, fn
      %{^type => payload} -> %{type => fun.(payload)}
      envelope -> envelope
    end)
  end

  test "schema rejects missing, unknown, mistyped and out-of-range fields before scrubbing" do
    stream = minimal()

    mutations = [
      {"meta", &Map.delete(&1, "runtime")},
      {"meta", &Map.put(&1, "protocolVersion", 33)},
      {"testRunStarted", &put_in(&1, ["timestamp", "nanos"], 1_000_000_000)},
      {"testStepFinished", &put_in(&1, ["testStepResult", "duration", "seconds"], "bad")},
      {"testStepFinished", &put_in(&1, ["testStepResult", "status"], "PASS")},
      {"testStepFinished", &put_in(&1, ["testStepResult", "exception"], %{"type" => 123})},
      {"stepDefinition", &put_in(&1, ["sourceReference", "location", "line"], "3")},
      {"testCase", &put_in(&1, ["testSteps", Access.at(0), "stepMatchArgumentsLists"], "bad")},
      {"source", &Map.put(&1, "unexpected", true)}
    ]

    for {type, fun} <- mutations do
      assert_raise ExUnit.AssertionError, fn ->
        stream |> change(type, fun) |> Enum.each(&CckSchema.assert_valid/1)
      end
    end

    for envelope <- [%{}, %{"meta" => %{}, "source" => %{}}, %{"unknown" => %{}}] do
      assert_raise ExUnit.AssertionError, fn -> CckSchema.assert_valid(envelope) end
    end
  end

  test "raw validation cannot be bypassed by approval drops" do
    bad = change(minimal(), "testStepFinished", &Map.put(&1, "timestamp", "invalid"))

    assert_raise ExUnit.AssertionError, fn ->
      Cucumber.CckApproval.assert_equivalent(bad, minimal(), drop: ["testStepFinished"])
    end
  end

  test "duplicate, dangling, forward and wrong-type references are rejected" do
    stream = minimal()
    definition = Enum.find(stream, &Map.has_key?(&1, "stepDefinition"))
    without = Enum.reject(stream, &Map.has_key?(&1, "stepDefinition"))

    for bad <- [
          List.insert_at(stream, 5, definition),
          change(stream, "testCase", &Map.put(&1, "pickleId", "missing")),
          change(stream, "testCase", &Map.put(&1, "pickleId", "4")),
          change(stream, "testCase", &Map.put(&1, "pickleId", "2")),
          List.insert_at(without, -2, definition)
        ] do
      assert_raise ExUnit.AssertionError, fn -> CckStream.assert_valid(bad) end
    end
  end

  test "missing or repeated lifecycle events and unfinished work are rejected" do
    stream = minimal()

    for type <-
          ~w(meta testRunStarted testCaseStarted testStepStarted testStepFinished testCaseFinished testRunFinished) do
      missing = Enum.reject(stream, &Map.has_key?(&1, type))
      event = Enum.find(stream, &Map.has_key?(&1, type))
      index = Enum.find_index(stream, &Map.has_key?(&1, type))
      repeated = List.insert_at(stream, index, event)

      for bad <- [missing, repeated] do
        assert_raise ExUnit.AssertionError, fn -> CckStream.assert_valid(bad) end
      end
    end

    assert_raise ExUnit.AssertionError, fn ->
      stream
      |> change("meta", &Map.put(&1, "protocolVersion", "27.0.0"))
      |> CckStream.assert_valid()
    end
  end

  test "concurrent attempts may interleave but cannot finish or attach to each other's steps" do
    stream = minimal()
    prefix = Enum.take(stream, 7)
    [started, step_started, step_finished, finished, run_finished] = Enum.drop(stream, 7)

    other_case =
      List.last(prefix)
      |> put_in(["testCase", "id"], "other-case")
      |> put_in(["testCase", "testSteps", Access.at(0), "id"], "other-step")

    prefix = prefix ++ [other_case]

    other_started =
      started
      |> put_in(["testCaseStarted", "id"], "other")
      |> put_in(["testCaseStarted", "testCaseId"], "other-case")

    other = fn envelope ->
      [{type, payload}] = Map.to_list(envelope)
      payload = Map.put(payload, "testCaseStartedId", "other")

      payload =
        if Map.has_key?(payload, "testStepId"),
          do: Map.put(payload, "testStepId", "other-step"),
          else: payload

      %{type => payload}
    end

    attachment = %{
      "attachment" => %{
        "body" => "evidence",
        "mediaType" => "text/plain",
        "contentEncoding" => "IDENTITY",
        "testCaseStartedId" => "8",
        "testStepId" => "7"
      }
    }

    interleaved =
      prefix ++
        [
          started,
          other_started,
          step_started,
          other.(step_started),
          attachment,
          other.(step_finished),
          other.(finished),
          step_finished,
          finished,
          run_finished
        ]

    assert :ok = CckStream.assert_valid(interleaved)

    cross_case = put_in(attachment, ["attachment", "testStepId"], "other-step")

    assert_raise ExUnit.AssertionError, fn ->
      interleaved |> List.insert_at(12, cross_case) |> CckStream.assert_valid()
    end

    for index <- [10, 17] do
      assert_raise ExUnit.AssertionError, fn ->
        List.insert_at(interleaved, index, other.(attachment)) |> CckStream.assert_valid()
      end
    end

    assert_raise ExUnit.AssertionError, fn ->
      (prefix ++
         [started, other_started, step_started, other.(step_finished), finished, run_finished])
      |> CckStream.assert_valid()
    end
  end

  test "attachments are rejected outside the active step window" do
    stream = minimal()

    attachment = %{
      "attachment" => %{
        "body" => "note",
        "mediaType" => "text/plain",
        "contentEncoding" => "IDENTITY",
        "testCaseStartedId" => "8",
        "testStepId" => "7"
      }
    }

    assert :ok = stream |> List.insert_at(9, attachment) |> CckStream.assert_valid()

    for index <- [8, 10, 11, 12] do
      assert_raise ExUnit.AssertionError, fn ->
        stream |> List.insert_at(index, attachment) |> CckStream.assert_valid()
      end
    end
  end
end
