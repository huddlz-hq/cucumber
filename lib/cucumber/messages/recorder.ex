defmodule Cucumber.Messages.Recorder do
  @moduledoc false

  # The Cucumber Messages stream of one run, as a pure value: run-time
  # events go in, envelopes come out. Cucumber.RunCoordinator holds the
  # recorder and feeds it events one at a time, which is what keeps the
  # stream ordered under @async features; the recorder itself does no I/O
  # and reads no clock (`now` is passed with every event).
  #
  # It owns every rule about the stream's shape:
  #
  #   * run-unique, sequential message ids
  #   * testRunStarted, emitted once before the first run-time envelope
  #   * which test steps of each attempt have started and finished
  #   * the status of a test step that never ran: SKIPPED, or UNDEFINED /
  #     AMBIGUOUS when the step matched no definition (or several) and the
  #     scenario stopped failed-ish
  #   * UNKNOWN for attempts still open when the run ends (a killed test
  #     process) and for steps that started but never finished
  #   * testRunFinished, failed when any run hook failed
  #   * NDJSON encoding
  #
  # A disabled recorder (messages off) ignores every event and replies nil,
  # so no caller has to check whether messages are on.

  alias Cucumber.Messages
  alias Cucumber.TestCase

  @typedoc false
  @type event ::
          {:open_test_case, TestCase.t()}
          | {:start_attempt, test_case_id :: String.t(), attempt :: pos_integer()}
          | {:step_started, case_started_id :: String.t(), step_id :: String.t()}
          | {:step_finished, case_started_id :: String.t(), step_id :: String.t(),
             Messages.status(), duration_ns :: integer(), error_message :: String.t() | nil}
          | {:skip_unexecuted, case_started_id :: String.t(), :skipped | :failedish}
          | {:close_attempt, case_started_id :: String.t(), will_be_retried :: boolean()}
          | {:attachment, Cucumber.Attachment.t(), message_ref :: map() | nil}
          | {:run_hook_started, hook_ref :: {module(), atom()}}
          | {:run_hook_finished, started_id :: String.t(), Messages.status(),
             duration_ns :: integer()}
          | {:finish_run, test_cases_passed :: boolean()}

  defstruct enabled: false,
            envelopes: [],
            next_id: 0,
            step_definition_ids: %{},
            hook_ids: %{},
            run_started_id: nil,
            test_cases: %{},
            attempts: %{},
            run_hook_failed: false

  @opaque t :: %__MODULE__{}

  @doc false
  # The recorder for a run with messages off.
  @spec disabled() :: t()
  def disabled, do: %__MODULE__{}

  @doc false
  # A recorder for a run with messages on. `static_envelopes` (meta,
  # sources, pickles, definitions...) open the stream in the given order;
  # ids continue from `next_id`. Run-time envelopes reference step
  # definitions by `step_definition_ids` (definition position => id) and
  # hooks by `hook_ids` (hook ref => id).
  @spec new([Messages.envelope()], non_neg_integer(), map(), map()) :: t()
  def new(static_envelopes, next_id, step_definition_ids, hook_ids) do
    %__MODULE__{
      enabled: true,
      envelopes: Enum.reverse(static_envelopes),
      next_id: next_id,
      step_definition_ids: step_definition_ids,
      hook_ids: hook_ids
    }
  end

  @doc false
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{enabled: enabled}), do: enabled

  @doc false
  # Records one event at system time `now` (nanoseconds) and returns the
  # reply for the caller with the updated recorder. Replies:
  #
  #   * :open_test_case - `%{test_case_id: id, step_ids: %{position => id}}`
  #   * :start_attempt - the attempt's testCaseStarted id
  #   * :run_hook_started - the testRunHookStarted id
  #   * anything else - :ok
  #
  # A disabled recorder replies nil to every event.
  @spec record(t(), event(), integer()) :: {term(), t()}
  def record(%__MODULE__{enabled: false} = recorder, _event, _now), do: {nil, recorder}

  def record(recorder, event, now) do
    now = Messages.timestamp(now)

    recorder
    |> ensure_run_started(now)
    |> apply_event(event, now)
  end

  @doc false
  # Every envelope recorded so far, in stream order.
  @spec envelopes(t()) :: [Messages.envelope()]
  def envelopes(%__MODULE__{envelopes: envelopes}), do: Enum.reverse(envelopes)

  @doc false
  # The stream as NDJSON: one encoded envelope per line.
  @spec to_ndjson(t()) :: iodata()
  def to_ndjson(recorder) do
    recorder |> envelopes() |> Enum.map(&[Messages.encode!(&1), "\n"])
  end

  # Emits testRunStarted exactly once, after all static envelopes and
  # before any run-time envelope.
  defp ensure_run_started(%__MODULE__{run_started_id: nil} = recorder, now) do
    {[id], recorder} = take_ids(recorder, 1)

    %{recorder | run_started_id: id}
    |> append([Messages.test_run_started(id, now)])
  end

  defp ensure_run_started(recorder, _now), do: recorder

  # Allocates ids for the test case and each of its test steps (keyed by
  # position) and emits the testCase envelope. Remembers, per test step,
  # the status it reports if it never runs after a failed-ish stop, and
  # which steps are skipped before the after hooks run.
  defp apply_event(recorder, {:open_test_case, %TestCase{} = test_case}, _now) do
    test_steps = TestCase.test_steps(test_case)
    {[test_case_id | ids], recorder} = take_ids(recorder, length(test_steps) + 1)
    step_ids = test_steps |> Enum.map(& &1.position) |> Enum.zip(ids) |> Map.new()

    envelope =
      Messages.test_case(
        test_case_id,
        test_case.pickle_id,
        Enum.map(test_steps, &test_step_envelope(recorder, &1, step_ids)),
        recorder.run_started_id
      )

    unrun = fn test_step ->
      {Map.fetch!(step_ids, test_step.position), never_ran_status(test_step)}
    end

    planned = %{
      steps: Enum.map(test_steps, unrun),
      skippable: Enum.map(test_case.before_hooks ++ test_case.pickle_test_steps, unrun)
    }

    recorder = put_in(recorder.test_cases[test_case_id], planned)
    {%{test_case_id: test_case_id, step_ids: step_ids}, append(recorder, [envelope])}
  end

  # Emits testCaseStarted for one attempt (1-based here, 0-based in the
  # message).
  defp apply_event(recorder, {:start_attempt, test_case_id, attempt}, now) do
    {[id], recorder} = take_ids(recorder, 1)
    tracking = %{test_case_id: test_case_id, started: MapSet.new(), finished: MapSet.new()}
    recorder = put_in(recorder.attempts[id], tracking)
    {id, append(recorder, [Messages.test_case_started(id, test_case_id, attempt - 1, now)])}
  end

  defp apply_event(recorder, {:step_started, case_started_id, step_id}, now) do
    recorder
    |> append([Messages.test_step_started(case_started_id, step_id, now)])
    |> ok()
  end

  defp apply_event(
         recorder,
         {:step_finished, case_started_id, step_id, status, duration, error_message},
         now
       ) do
    result = Messages.test_step_result(status, duration, error_message)

    recorder
    |> append([Messages.test_step_finished(case_started_id, step_id, result, now)])
    |> ok()
  end

  # Before-hook and pickle steps that haven't run when the after hooks
  # start get their events now, so they precede the after-hook events in
  # the stream (reference ordering). After a deliberate skip everything is
  # SKIPPED, even steps that could never have matched; after a failed-ish
  # stop (failure, pending, undefined, ambiguous) unmatched steps report
  # UNDEFINED/AMBIGUOUS.
  defp apply_event(recorder, {:skip_unexecuted, case_started_id, outcome}, now) do
    case Map.fetch(recorder.attempts, case_started_id) do
      :error ->
        ok(recorder)

      {:ok, tracking} ->
        planned = Map.fetch!(recorder.test_cases, tracking.test_case_id)

        recorder
        |> report_unrun(case_started_id, tracking, planned.skippable, outcome, now)
        |> ok()
    end
  end

  defp apply_event(recorder, {:close_attempt, case_started_id, will_be_retried}, now) do
    recorder |> close_attempt(case_started_id, :failedish, will_be_retried, now) |> ok()
  end

  defp apply_event(recorder, {:attachment, attachment, message_ref}, _now) do
    recorder |> append([Messages.attachment(attachment, message_ref)]) |> ok()
  end

  defp apply_event(recorder, {:run_hook_started, hook_ref}, now) do
    {[id], recorder} = take_ids(recorder, 1)
    hook_id = Map.get(recorder.hook_ids, hook_ref)
    envelope = Messages.test_run_hook_started(id, recorder.run_started_id, hook_id, now)
    {id, append(recorder, [envelope])}
  end

  defp apply_event(recorder, {:run_hook_finished, started_id, status, duration}, now) do
    result = Messages.test_step_result(status, duration)
    recorder = append(recorder, [Messages.test_run_hook_finished(started_id, result, now)])
    ok(%{recorder | run_hook_failed: recorder.run_hook_failed or status == :failed})
  end

  # Closes every attempt the runner never finished (UNKNOWN: a dead test
  # process says nothing about why its steps didn't run), then emits
  # testRunFinished. A failed run hook fails the run even when every test
  # case passed (an after_all error surfaces after ExUnit counted results).
  defp apply_event(recorder, {:finish_run, test_cases_passed}, now) do
    recorder =
      recorder.attempts
      |> Map.keys()
      |> Enum.reduce(recorder, &close_attempt(&2, &1, :unknown, false, now))

    success = test_cases_passed and not recorder.run_hook_failed
    ok(append(recorder, [Messages.test_run_finished(success, now, recorder.run_started_id)]))
  end

  defp ok(recorder), do: {:ok, recorder}

  defp test_step_envelope(recorder, %TestCase.HookStep{} = hook_step, step_ids) do
    %{
      id: Map.fetch!(step_ids, hook_step.position),
      hookId: Map.get(recorder.hook_ids, hook_step.ref)
    }
  end

  defp test_step_envelope(recorder, %TestCase.PickleTestStep{} = test_step, step_ids) do
    %{
      id: Map.fetch!(step_ids, test_step.position),
      pickleStepId: test_step.pickle_step_id,
      stepDefinitionIds:
        Enum.map(
          matched_definitions(test_step.match),
          &Map.fetch!(recorder.step_definition_ids, &1.position)
        )
    }
  end

  # Every definition the step matched — one, none, or all of an ambiguous
  # set (in definition order, so ids ascend)
  defp matched_definitions({:ok, definition}), do: [definition]
  defp matched_definitions(:undefined), do: []
  defp matched_definitions({:ambiguous, definitions}), do: definitions

  # A pickle step that matches no definition can only ever be UNDEFINED,
  # and one that matches several AMBIGUOUS — even when it never ran because
  # the scenario stopped earlier. Other steps have no status of their own.
  defp never_ran_status(%TestCase.PickleTestStep{match: :undefined}), do: :undefined
  defp never_ran_status(%TestCase.PickleTestStep{match: {:ambiguous, _}}), do: :ambiguous
  defp never_ran_status(_test_step), do: nil

  # Reports the attempt's steps that never ran, then emits testCaseFinished.
  # `stop` is how the attempt ended (see report_unrun/6). A second close of
  # the same attempt is a no-op, so finish-time reconciliation can't
  # double-close. A normal close is a failed-ish stop: stops that never
  # reach :skip_unexecuted (a failing before hook, a raising background
  # step) close through this path alone, and a deliberate skip's steps were
  # already reported SKIPPED before the attempt closes.
  defp close_attempt(recorder, case_started_id, stop, will_be_retried, now) do
    case Map.pop(recorder.attempts, case_started_id) do
      {nil, _attempts} ->
        recorder

      {tracking, attempts} ->
        planned = Map.fetch!(recorder.test_cases, tracking.test_case_id)
        recorder = report_unrun(recorder, case_started_id, tracking, planned.steps, stop, now)
        finished = Messages.test_case_finished(case_started_id, now, will_be_retried)
        append(%{recorder | attempts: attempts}, [finished])
    end
  end

  # Reports each of `steps` ({step id, never-ran status}) that hasn't
  # finished, with the status `stop` gives it: `:skipped` (a deliberate
  # skip) reports SKIPPED even for steps that could never have matched,
  # `:failedish` keeps an unmatched step's UNDEFINED/AMBIGUOUS, and
  # `:unknown` (a dead test process says nothing about why) reports
  # UNKNOWN.
  defp report_unrun(recorder, case_started_id, tracking, steps, stop, now) do
    Enum.reduce(steps, recorder, fn {step_id, never_ran_status}, recorder ->
      status = unrun_status(stop, never_ran_status)
      synthesize_step(recorder, case_started_id, step_id, tracking, status, now)
    end)
  end

  defp unrun_status(:failedish, never_ran_status), do: never_ran_status || :skipped
  defp unrun_status(stop, _never_ran_status), do: stop

  # A step that never ran gets a started/finished pair with `status`; a
  # step that started but never finished (the test process died mid-step)
  # gets an UNKNOWN finish. Reads the attempt's tracking as it was when the
  # synthesis began, which is what it needs: synthesized steps are distinct.
  defp synthesize_step(recorder, case_started_id, step_id, tracking, status, now) do
    cond do
      MapSet.member?(tracking.finished, step_id) ->
        recorder

      MapSet.member?(tracking.started, step_id) ->
        result = Messages.test_step_result(:unknown, 0)
        append(recorder, [Messages.test_step_finished(case_started_id, step_id, result, now)])

      true ->
        result = Messages.test_step_result(status, 0)

        append(recorder, [
          Messages.test_step_started(case_started_id, step_id, now),
          Messages.test_step_finished(case_started_id, step_id, result, now)
        ])
    end
  end

  # Appends envelopes to the stream, tracking each test step event against
  # its attempt (synthesized ones included) so no step finishes twice.
  defp append(recorder, envelopes) do
    Enum.reduce(envelopes, recorder, fn envelope, recorder ->
      recorder = track(recorder, envelope)
      %{recorder | envelopes: [envelope | recorder.envelopes]}
    end)
  end

  defp track(recorder, %{testStepStarted: %{testCaseStartedId: id, testStepId: step_id}}),
    do: track_step(recorder, id, :started, step_id)

  defp track(recorder, %{testStepFinished: %{testCaseStartedId: id, testStepId: step_id}}),
    do: track_step(recorder, id, :finished, step_id)

  defp track(recorder, _envelope), do: recorder

  defp track_step(recorder, case_started_id, key, step_id) do
    case recorder.attempts do
      %{^case_started_id => tracking} ->
        tracking = Map.update!(tracking, key, &MapSet.put(&1, step_id))
        put_in(recorder.attempts[case_started_id], tracking)

      _closed_or_unknown ->
        recorder
    end
  end

  defp take_ids(recorder, n) do
    ids = Enum.map(recorder.next_id..(recorder.next_id + n - 1)//1, &Integer.to_string/1)
    {ids, %{recorder | next_id: recorder.next_id + n}}
  end
end
