defmodule Cucumber.Messages.RecorderTest do
  use ExUnit.Case, async: true

  alias Cucumber.Messages.Recorder
  alias Cucumber.StepRegistry.Definition
  alias Cucumber.TestCase
  alias Cucumber.TestCase.HookStep
  alias Cucumber.TestCase.PickleTestStep

  @before_hook {__MODULE__, :before_hook}
  @after_hook {__MODULE__, :after_hook}
  @run_hook {__MODULE__, :run_hook}

  # Ids continue from 10: "10" is testRunStarted, "11" the test case, "12"
  # to "16" its test steps by position, and "17" the first attempt.
  setup do
    recorder =
      Recorder.new(
        [%{meta: %{}}],
        10,
        %{0 => "def-0", 1 => "def-1"},
        %{@before_hook => "hook-before", @after_hook => "hook-after", @run_hook => "hook-run"}
      )

    %{recorder: recorder}
  end

  # Position 0: before hook; 1: matches one definition; 2: matches none;
  # 3: matches two; 4: after hook.
  defp test_case do
    %TestCase{
      pickle_id: "pickle-1",
      before_hooks: [%HookStep{position: 0, name: nil, ref: @before_hook}],
      pickle_test_steps: [
        pickle_test_step(1, {:ok, definition(0)}),
        pickle_test_step(2, :undefined),
        pickle_test_step(3, {:ambiguous, [definition(0), definition(1)]})
      ],
      after_hooks: [%HookStep{position: 4, name: nil, ref: @after_hook}]
    }
  end

  defp pickle_test_step(position, match) do
    %PickleTestStep{
      position: position,
      step: %Gherkin.Step{keyword: "Given ", text: "step #{position}", line: position},
      pickle_step_id: "pickle-step-#{position}",
      background?: false,
      match: match
    }
  end

  defp definition(position) do
    %Definition{
      position: position,
      kind: :expression,
      source: "step",
      module: __MODULE__,
      function: :step,
      file: "steps.exs",
      line: position + 1,
      matcher: nil
    }
  end

  # Records events at time 0, returning the replies and the recorder
  defp record(recorder, events) do
    Enum.map_reduce(events, recorder, &Recorder.record(&2, &1, 0))
  end

  defp open_attempt(recorder) do
    {[_test_case, case_started_id], recorder} =
      record(recorder, [{:open_test_case, test_case()}, {:start_attempt, "11", 1}])

    {case_started_id, recorder}
  end

  defp payloads(recorder, key) do
    for %{^key => payload} <- Recorder.envelopes(recorder), do: payload
  end

  # Every testStepFinished as {test step id, status}, in stream order
  defp step_statuses(recorder) do
    for finished <- payloads(recorder, :testStepFinished),
        do: {finished.testStepId, finished.testStepResult.status}
  end

  describe "disabled/0" do
    test "ignores every event, replying nil" do
      recorder = Recorder.disabled()

      assert {[nil, nil, nil], ^recorder} =
               record(recorder, [
                 {:open_test_case, test_case()},
                 {:start_attempt, "1", 1},
                 {:finish_run, true}
               ])

      refute Recorder.enabled?(recorder)
      assert Recorder.envelopes(recorder) == []
    end
  end

  describe "the stream" do
    test "opens with the static envelopes, then testRunStarted once", %{recorder: recorder} do
      {_replies, recorder} =
        record(recorder, [{:run_hook_started, @run_hook}, {:open_test_case, test_case()}])

      assert [%{meta: %{}}, %{testRunStarted: %{id: "10"}} | rest] = Recorder.envelopes(recorder)
      refute Enum.any?(rest, &Map.has_key?(&1, :testRunStarted))
    end

    test "encodes as one JSON object per line", %{recorder: recorder} do
      {_replies, recorder} = record(recorder, [{:open_test_case, test_case()}])

      lines = recorder |> Recorder.to_ndjson() |> IO.iodata_to_binary() |> String.split("\n")

      assert [~s({"meta":{}}), started, test_case, ""] = lines
      assert %{"testRunStarted" => %{"id" => "10"}} = JSON.decode!(started)
      assert %{"testCase" => %{"id" => "11"}} = JSON.decode!(test_case)
    end
  end

  describe "{:open_test_case, test_case}" do
    test "allocates ids for the test case and each test step by position", %{recorder: recorder} do
      {[reply], _recorder} = record(recorder, [{:open_test_case, test_case()}])

      assert reply == %{
               test_case_id: "11",
               step_ids: %{0 => "12", 1 => "13", 2 => "14", 3 => "15", 4 => "16"}
             }
    end

    test "emits the testCase with each step's hook or matched definitions", %{recorder: recorder} do
      {_replies, recorder} = record(recorder, [{:open_test_case, test_case()}])

      assert [test_case] = payloads(recorder, :testCase)

      assert test_case == %{
               id: "11",
               pickleId: "pickle-1",
               testRunStartedId: "10",
               testSteps: [
                 %{id: "12", hookId: "hook-before"},
                 %{id: "13", pickleStepId: "pickle-step-1", stepDefinitionIds: ["def-0"]},
                 %{id: "14", pickleStepId: "pickle-step-2", stepDefinitionIds: []},
                 %{
                   id: "15",
                   pickleStepId: "pickle-step-3",
                   stepDefinitionIds: ["def-0", "def-1"]
                 },
                 %{id: "16", hookId: "hook-after"}
               ]
             }
    end
  end

  describe "{:start_attempt, test_case_id, attempt}" do
    test "emits a testCaseStarted per attempt, numbered from 0", %{recorder: recorder} do
      {[_test_case, first, second], recorder} =
        record(recorder, [
          {:open_test_case, test_case()},
          {:start_attempt, "11", 1},
          {:start_attempt, "11", 2}
        ])

      assert {first, second} == {"17", "18"}

      assert [%{id: "17", attempt: 0}, %{id: "18", attempt: 1}] =
               payloads(recorder, :testCaseStarted)
    end
  end

  describe "steps that ran" do
    test "are reported as the runner reports them", %{recorder: recorder} do
      {attempt, recorder} = open_attempt(recorder)

      {_replies, recorder} =
        record(recorder, [
          {:step_started, attempt, "12"},
          {:step_finished, attempt, "12", :passed, 1_500, nil},
          {:step_started, attempt, "13"},
          {:step_finished, attempt, "13", :failed, 2_000, "boom"}
        ])

      assert [%{testStepId: "12"}, %{testStepId: "13"}] = payloads(recorder, :testStepStarted)

      assert [
               %{testStepId: "12", testStepResult: %{status: "PASSED"}},
               %{testStepId: "13", testStepResult: %{status: "FAILED", message: "boom"}}
             ] = payloads(recorder, :testStepFinished)
    end
  end

  describe "{:skip_unexecuted, case_started_id, outcome}" do
    test "after a deliberate skip, every unrun step before the after hooks is SKIPPED", %{
      recorder: recorder
    } do
      {attempt, recorder} = open_attempt(recorder)

      {_replies, recorder} =
        record(recorder, [
          {:step_started, attempt, "12"},
          {:step_finished, attempt, "12", :passed, 0, nil},
          {:step_started, attempt, "13"},
          {:step_finished, attempt, "13", :skipped, 0, nil},
          {:skip_unexecuted, attempt, :skipped}
        ])

      assert step_statuses(recorder) == [
               {"12", "PASSED"},
               {"13", "SKIPPED"},
               {"14", "SKIPPED"},
               {"15", "SKIPPED"}
             ]
    end

    test "after a failed-ish stop, unmatched steps keep UNDEFINED and AMBIGUOUS", %{
      recorder: recorder
    } do
      {attempt, recorder} = open_attempt(recorder)

      {_replies, recorder} =
        record(recorder, [
          {:step_started, attempt, "12"},
          {:step_finished, attempt, "12", :failed, 0, "boom"},
          {:skip_unexecuted, attempt, :failedish}
        ])

      assert step_statuses(recorder) == [
               {"12", "FAILED"},
               {"13", "SKIPPED"},
               {"14", "UNDEFINED"},
               {"15", "AMBIGUOUS"}
             ]
    end

    test "is a no-op for an attempt that is not open", %{recorder: recorder} do
      {_replies, recorder} = record(recorder, [{:open_test_case, test_case()}])

      assert {:ok, ^recorder} = Recorder.record(recorder, {:skip_unexecuted, "99", :skipped}, 0)
    end
  end

  describe "{:close_attempt, case_started_id, will_be_retried}" do
    test "reports every step that never ran, then finishes the test case", %{
      recorder: recorder
    } do
      {attempt, recorder} = open_attempt(recorder)

      # A failing before hook: nothing else ran and :skip_unexecuted never came
      {_replies, recorder} =
        record(recorder, [
          {:step_started, attempt, "12"},
          {:step_finished, attempt, "12", :failed, 0, "boom"},
          {:close_attempt, attempt, true}
        ])

      assert step_statuses(recorder) == [
               {"12", "FAILED"},
               {"13", "SKIPPED"},
               {"14", "UNDEFINED"},
               {"15", "AMBIGUOUS"},
               {"16", "SKIPPED"}
             ]

      assert [%{testCaseStartedId: ^attempt, willBeRetried: true}] =
               payloads(recorder, :testCaseFinished)
    end

    test "doesn't report a step twice after :skip_unexecuted", %{recorder: recorder} do
      {attempt, recorder} = open_attempt(recorder)

      {_replies, recorder} =
        record(recorder, [
          {:skip_unexecuted, attempt, :skipped},
          {:step_started, attempt, "16"},
          {:step_finished, attempt, "16", :passed, 0, nil},
          {:close_attempt, attempt, false}
        ])

      assert Enum.map(step_statuses(recorder), &elem(&1, 0)) == ["12", "13", "14", "15", "16"]
    end

    test "finishes a step that started but never finished as UNKNOWN", %{recorder: recorder} do
      {attempt, recorder} = open_attempt(recorder)

      {_replies, recorder} =
        record(recorder, [{:step_started, attempt, "12"}, {:close_attempt, attempt, false}])

      assert [%{testStepId: "12"} | _skipped] = payloads(recorder, :testStepStarted)
      assert length(payloads(recorder, :testStepStarted)) == 5
      assert [{"12", "UNKNOWN"} | _skipped] = step_statuses(recorder)
    end

    test "closing an attempt twice is a no-op", %{recorder: recorder} do
      {attempt, recorder} = open_attempt(recorder)
      {:ok, closed} = Recorder.record(recorder, {:close_attempt, attempt, false}, 0)

      assert {:ok, ^closed} = Recorder.record(closed, {:close_attempt, attempt, false}, 0)
    end
  end

  describe "{:finish_run, test_cases_passed}" do
    test "closes attempts still open with every unrun step UNKNOWN", %{recorder: recorder} do
      {attempt, recorder} = open_attempt(recorder)
      {_replies, recorder} = record(recorder, [{:finish_run, false}])

      assert Enum.map(step_statuses(recorder), &elem(&1, 1)) == List.duplicate("UNKNOWN", 5)

      assert [%{testCaseStartedId: ^attempt, willBeRetried: false}] =
               payloads(recorder, :testCaseFinished)

      assert [%{success: false, testRunStartedId: "10"}] = payloads(recorder, :testRunFinished)
    end

    test "the run succeeds when every test case passed and no run hook failed", %{
      recorder: recorder
    } do
      {_replies, recorder} = record(recorder, [{:finish_run, true}])

      assert [%{success: true}] = payloads(recorder, :testRunFinished)
    end

    test "a failed run hook fails the run", %{recorder: recorder} do
      {[started_id], recorder} = record(recorder, [{:run_hook_started, @run_hook}])

      {_replies, recorder} =
        record(recorder, [{:run_hook_finished, started_id, :failed, 0}, {:finish_run, true}])

      assert [%{success: false}] = payloads(recorder, :testRunFinished)
    end
  end

  describe "run hooks" do
    test "are bracketed with testRunHookStarted and testRunHookFinished", %{recorder: recorder} do
      {[started_id, :ok], recorder} =
        record(recorder, [
          {:run_hook_started, @run_hook},
          {:run_hook_finished, "11", :passed, 1_000}
        ])

      assert started_id == "11"

      assert [%{id: "11", hookId: "hook-run", testRunStartedId: "10"}] =
               payloads(recorder, :testRunHookStarted)

      assert [%{testRunHookStartedId: "11", result: %{status: "PASSED"}}] =
               payloads(recorder, :testRunHookFinished)
    end
  end

  describe "{:attachment, attachment, message_ref}" do
    test "lands in stream order on the step it was recorded in", %{recorder: recorder} do
      {attempt, recorder} = open_attempt(recorder)
      attachment = %Cucumber.Attachment{body: "hi", media_type: "text/plain", encoding: :identity}

      {_replies, recorder} =
        record(recorder, [
          {:step_started, attempt, "12"},
          {:attachment, attachment, %{test_case_started_id: attempt, test_step_id: "12"}},
          {:step_finished, attempt, "12", :passed, 0, nil}
        ])

      assert [%{testStepStarted: _}, %{attachment: payload}, %{testStepFinished: _}] =
               recorder |> Recorder.envelopes() |> Enum.take(-3)

      assert %{body: "hi", testCaseStartedId: ^attempt, testStepId: "12"} = payload
    end
  end
end
