defmodule Cucumber.RunCoordinator do
  @moduledoc """
  Run-wide coordination process for cucumber test runs.

  Started (or reset) by `Cucumber.compile_features!/1` — which runs from
  `test_helper.exs` before any test executes, so startup is race-free. State
  is keyed by a run id that changes on every `compile_features!` call, so
  repeated runs in one VM (`mix test.watch`, test harnesses) never see stale
  state.

  Current run-scoped concerns:

    * **BeforeAll once-guard** — `before_all_context/1` runs the run's
      `before_all` hooks exactly once (serialized through the GenServer, so
      concurrent `@async` scenarios are safe) and caches the merged context
      (or the first error) for every subsequent scenario.
    * **AfterAll hand-off** — `register_after_all/1` stores the run's
      `after_all` hooks; the `ExUnit.after_suite/1` callback registered by
      the compiler claims them exactly once via `run_after_all/1`.
    * **Attachments** — `record_attachment/2` collects
      `Cucumber.Attachment` structs (see `Cucumber.attach/4`) in run order;
      `attachments/0` returns them.
    * **Cucumber Messages sink** — when `config :cucumber, messages: path`
      is set, `Cucumber.Messages.Emitter` configures the sink with the
      run's static envelopes and id maps (`configure_messages/1`); the
      runner then appends run-time envelopes in order (`emit_runtime/1`,
      `take_message_ids/1`, `finish_test_case/3`), and the `after_suite`
      callback flushes the NDJSON file (`flush_messages/1`), reconciling
      test cases the runner never finished (e.g. a killed test process).
      Serializing emission through this process is what keeps the stream
      ordered under `@async` features. Note that `ExUnit.after_suite/1`
      callbacks fire on *every* `ExUnit.run/1` — the sink flushes (and
      disables itself) when the first run in the VM completes, so a project
      that invokes a nested `ExUnit.run/1` mid-suite with the sink enabled
      gets the stream truncated at that point (`Cucumber.BehaviorCase`
      relies on exactly this per-run firing to capture streams in tests).
  """

  use GenServer

  @doc """
  Starts the coordinator for a new run, or resets it if already running.

  Returns the new run id.
  """
  @spec ensure_started() :: integer()
  def ensure_started do
    run_id = :erlang.unique_integer([:positive])

    # Deliberately unlinked: the caller (typically test_helper.exs) finishes
    # long before the run does.
    case GenServer.start(__MODULE__, run_id, name: __MODULE__) do
      {:ok, _pid} -> run_id
      {:error, {:already_started, _pid}} -> GenServer.call(__MODULE__, {:reset, run_id})
    end
  end

  @doc "Returns the current run id."
  @spec run_id() :: integer()
  def run_id do
    GenServer.call(__MODULE__, :run_id)
  end

  @doc false
  # Runs the run's before_all hooks exactly once and returns the resulting
  # context map (or the first error). `hooks` is the full hook list; only
  # :before_all entries matter, and only the first caller's are executed —
  # every module of a run carries the same discovery-wide list.
  #
  # CCK semantics: when a before_all hook fails, the *remaining* before_all
  # hooks still run (to set up as much as possible for cleanup), but the run
  # is failed — every scenario receives the first error.
  @spec before_all_context([Cucumber.Hooks.hook()]) :: {:ok, map()} | {:error, term()}
  def before_all_context(hooks) do
    case for {:before_all, _tag, name, ref} <- hooks, do: {name, ref} do
      [] ->
        {:ok, %{}}

      before_all_hooks ->
        ensure_process()
        GenServer.call(__MODULE__, {:before_all, before_all_hooks}, :infinity)
    end
  end

  @doc false
  # Stores the run's after_all hooks for the after_suite callback to claim.
  @spec register_after_all([Cucumber.Hooks.hook()]) :: :ok
  def register_after_all(hooks) do
    after_all_hooks = for {:after_all, _tag, name, ref} <- hooks, do: {name, ref}

    if after_all_hooks != [] do
      ensure_process()
      GenServer.call(__MODULE__, {:register_after_all, after_all_hooks})
    end

    :ok
  end

  @doc false
  # Records an attachment against the current run. Synchronous so that an
  # attachment recorded right before a step failure is reliably visible to
  # the failure-output formatting that follows. `message_ref` carries the
  # current `:test_case_started_id`/`:test_step_id` (or nil) so the sink can
  # emit an `attachment` envelope in stream order.
  @spec record_attachment(Cucumber.Attachment.t(), map() | nil) :: :ok
  def record_attachment(%Cucumber.Attachment{} = attachment, message_ref \\ nil) do
    ensure_process()
    GenServer.call(__MODULE__, {:record_attachment, attachment, message_ref})
  end

  @doc false
  # Enables the message sink for this run: `config` carries the output
  # `:path`, the static `:envelopes` (already in emission order), the
  # `:next_id` to continue id allocation from, and the `:step_definition_ids`
  # / `:hook_ids` maps the runner uses to reference static envelopes.
  @spec configure_messages(map()) :: :ok
  def configure_messages(config) do
    ensure_process()
    GenServer.call(__MODULE__, {:configure_messages, config})
  end

  @doc false
  # Returns what the runner needs to build a test case — the id maps and the
  # run's `testRunStarted` id — or nil when the sink is disabled. The first
  # call emits the `testRunStarted` envelope (after all static envelopes,
  # before any test case).
  @spec message_context() :: map() | nil
  def message_context do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :message_context)
    end
  end

  @doc false
  # Allocates `n` run-unique message ids (sequential strings), or nil when
  # the sink is disabled.
  @spec take_message_ids(pos_integer()) :: [String.t()] | nil
  def take_message_ids(n) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:take_message_ids, n})
    end
  end

  @doc false
  # Appends run-time envelopes to the stream in order. The sink tracks
  # testCase/testCaseStarted/testStep* envelopes so `finish_test_case/3`
  # and flush-time reconciliation know which planned steps never finished.
  @spec emit_runtime([Cucumber.Messages.envelope()]) :: :ok
  def emit_runtime(envelopes) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:emit_runtime, envelopes})
    end

    :ok
  end

  @doc false
  # Closes a test case: synthesizes testStepStarted/testStepFinished (with
  # `skip_status`, zero duration) for planned steps that never ran, then
  # emits testCaseFinished. Idempotent — a second call for the same id is a
  # no-op, so flush-time reconciliation can't double-close.
  @spec finish_test_case(String.t(), Cucumber.Messages.status(), boolean()) :: :ok
  def finish_test_case(test_case_started_id, skip_status, will_be_retried) do
    if Process.whereis(__MODULE__) do
      GenServer.call(
        __MODULE__,
        {:finish_test_case, test_case_started_id, skip_status, will_be_retried}
      )
    end

    :ok
  end

  @doc false
  # Synthesizes started/finished pairs for the given planned step ids of an
  # open test case that never ran. The runner calls this before the
  # after-scenario hooks, so skipped pickle steps precede the after-hook
  # events in the stream. After a `:failedish` stop, steps that match no
  # definition (or several) report UNDEFINED/AMBIGUOUS; after a `:skipped`
  # stop everything is SKIPPED.
  @spec skip_unfinished_steps(String.t(), [String.t()], :skipped | :failedish) :: :ok
  def skip_unfinished_steps(test_case_started_id, step_ids, outcome) do
    if Process.whereis(__MODULE__) do
      GenServer.call(
        __MODULE__,
        {:skip_unfinished_steps, test_case_started_id, step_ids, outcome}
      )
    end

    :ok
  end

  @doc false
  # Flushes the message stream to the configured NDJSON path: closes any
  # test case the runner never finished (status UNKNOWN), appends
  # testRunFinished, writes the file, and disables the sink. No-op when the
  # sink is not configured.
  @spec flush_messages(map()) :: :ok
  def flush_messages(suite_result) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:flush_messages, suite_result}, :infinity)
    end

    :ok
  end

  @doc false
  # Returns the run's attachments in the order they were recorded.
  @spec attachments() :: [Cucumber.Attachment.t()]
  def attachments do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :attachments)
    else
      []
    end
  end

  @doc false
  # The ExUnit.after_suite callback (registered once per VM by the compiler).
  #
  # Claims the current run's after_all hooks — exactly once per run — and
  # executes them in reverse definition order in the calling process. Every
  # hook runs even if an earlier one fails (cleanup effort, CCK semantics);
  # the first error is then reraised so the suite run fails.
  @spec run_after_all(map()) :: :ok
  def run_after_all(suite_result) do
    case take_after_all() do
      {[], _context} ->
        :ok

      {after_all_hooks, before_all_context} ->
        context = Map.put(before_all_context, :suite_result, suite_result)

        errors =
          after_all_hooks
          |> Enum.reverse()
          |> Enum.flat_map(fn hook -> run_after_all_hook(hook, context) end)

        case errors do
          [] -> :ok
          [{kind, reason, stacktrace} | _rest] -> :erlang.raise(kind, reason, stacktrace)
        end
    end
  end

  defp run_after_all_hook({name, ref}, context) do
    started_id = run_hook_started_call(ref)
    started_at = System.monotonic_time(:nanosecond)
    errors = apply_after_all_hook(name, ref, context)
    status = if errors == [], do: :passed, else: :failed
    run_hook_finished_call(started_id, status, System.monotonic_time(:nanosecond) - started_at)
    errors
  end

  defp apply_after_all_hook(name, {module, func_name}, context) do
    case apply(module, func_name, [context]) do
      {:error, reason} ->
        [{:error, after_all_error(name, reason), []}]

      _other ->
        []
    end
  catch
    kind, reason ->
      [{kind, reason, __STACKTRACE__}]
  end

  # after_all hooks run in the after_suite caller's process, so their
  # testRunHook envelopes go through the same GenServer calls the runner uses.
  defp run_hook_started_call(ref) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:run_hook_started, ref})
    end
  end

  defp run_hook_finished_call(nil, _status, _duration), do: :ok

  defp run_hook_finished_call(started_id, status, duration) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:run_hook_finished, started_id, status, duration})
    end

    :ok
  end

  defp after_all_error(name, reason) do
    label = if name, do: ~s( "#{name}"), else: ""
    %RuntimeError{message: "AfterAll hook#{label} failed: #{inspect(reason)}"}
  end

  defp take_after_all do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :take_after_all)
    else
      {[], %{}}
    end
  end

  # Starts the coordinator without resetting an existing run.
  defp ensure_process do
    case GenServer.start(__MODULE__, :erlang.unique_integer([:positive]), name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @impl true
  def init(run_id) do
    {:ok, initial_state(run_id)}
  end

  @impl true
  def handle_call({:reset, run_id}, _from, _state) do
    {:reply, run_id, initial_state(run_id)}
  end

  def handle_call(:run_id, _from, state) do
    {:reply, state.run_id, state}
  end

  def handle_call({:before_all, hooks}, _from, %{before_all: :not_run} = state) do
    {result, state} = execute_before_all(hooks, state)
    {:reply, result, %{state | before_all: result}}
  end

  def handle_call({:before_all, _hooks}, _from, state) do
    {:reply, state.before_all, state}
  end

  def handle_call({:register_after_all, hooks}, _from, state) do
    {:reply, :ok, %{state | after_all: hooks}}
  end

  def handle_call({:record_attachment, attachment, message_ref}, _from, state) do
    state =
      if state.messages do
        append_envelopes(state, [Cucumber.Messages.attachment(attachment, message_ref)])
      else
        state
      end

    {:reply, :ok, %{state | attachments: [attachment | state.attachments]}}
  end

  def handle_call({:configure_messages, config}, _from, state) do
    messages = %{
      path: config.path,
      envelopes: Enum.reverse(config.envelopes),
      next_id: config.next_id,
      step_definition_ids: config.step_definition_ids,
      hook_ids: config.hook_ids,
      run_started_id: nil,
      cases: %{},
      open_cases: %{},
      run_hook_failed: false
    }

    {:reply, :ok, %{state | messages: messages}}
  end

  def handle_call(:message_context, _from, %{messages: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call(:message_context, _from, state) do
    state = ensure_run_started(state)
    messages = state.messages

    context = %{
      step_definition_ids: messages.step_definition_ids,
      hook_ids: messages.hook_ids,
      test_run_started_id: messages.run_started_id
    }

    {:reply, context, state}
  end

  def handle_call({:take_message_ids, _n}, _from, %{messages: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call({:take_message_ids, n}, _from, state) do
    {ids, state} = allocate_ids(state, n)
    {:reply, ids, state}
  end

  def handle_call({:emit_runtime, _envelopes}, _from, %{messages: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:emit_runtime, envelopes}, _from, state) do
    {:reply, :ok, state |> ensure_run_started() |> append_envelopes(envelopes)}
  end

  def handle_call({:finish_test_case, _id, _status, _retried}, _from, %{messages: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(
        {:finish_test_case, case_started_id, skip_status, will_be_retried},
        _from,
        state
      ) do
    {:reply, :ok, close_test_case(state, case_started_id, skip_status, will_be_retried)}
  end

  def handle_call({:skip_unfinished_steps, _id, _ids, _outcome}, _from, %{messages: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:skip_unfinished_steps, case_started_id, step_ids, outcome}, _from, state) do
    {:reply, :ok, skip_unfinished(state, case_started_id, step_ids, outcome)}
  end

  def handle_call({:run_hook_started, ref}, _from, state) do
    {started_id, state} = run_hook_started(state, ref)
    {:reply, started_id, state}
  end

  def handle_call({:run_hook_finished, started_id, status, duration}, _from, state) do
    {:reply, :ok, run_hook_finished(state, started_id, status, duration)}
  end

  def handle_call({:flush_messages, _suite_result}, _from, %{messages: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:flush_messages, suite_result}, _from, state) do
    state = ensure_run_started(state)

    state =
      state.messages.open_cases
      |> Map.keys()
      |> Enum.reduce(state, &close_test_case(&2, &1, :unknown, false))

    # A failed BeforeAll/AfterAll hook fails the run even when every test
    # case passed (the AfterAll error surfaces after ExUnit counted results).
    success = Map.get(suite_result, :failures, 0) == 0 and not state.messages.run_hook_failed
    finished = Cucumber.Messages.test_run_finished(success, now(), state.messages.run_started_id)
    state = append_envelopes(state, [finished])

    write_messages(state.messages)
    {:reply, :ok, %{state | messages: nil}}
  end

  def handle_call(:attachments, _from, state) do
    {:reply, Enum.reverse(state.attachments), state}
  end

  def handle_call(:take_after_all, _from, state) do
    before_all_context =
      case state.before_all do
        {:ok, context} -> context
        _not_run_or_error -> %{}
      end

    {:reply, {state.after_all, before_all_context}, %{state | after_all: []}}
  end

  # Runs every before_all hook in definition order — even after one fails —
  # accumulating the merged context. The first error wins. Threads the sink
  # state to bracket each hook with testRunHookStarted/Finished envelopes.
  defp execute_before_all(hooks, state) do
    {{context, first_error}, state} =
      Enum.reduce(hooks, {{%{}, nil}, state}, fn {_name, ref} = hook,
                                                 {{context, first_error}, state} ->
        {started_id, state} = run_hook_started(state, ref)
        started_at = System.monotonic_time(:nanosecond)
        result = run_before_all_hook(hook, context)

        status =
          case result do
            {:ok, _context} -> :passed
            {:error, _error} -> :failed
          end

        duration = System.monotonic_time(:nanosecond) - started_at
        state = run_hook_finished(state, started_id, status, duration)

        case result do
          {:ok, context} -> {{context, first_error}, state}
          {:error, error} -> {{context, first_error || error}, state}
        end
      end)

    result = if first_error, do: {:error, first_error}, else: {:ok, context}
    {result, state}
  end

  defp run_before_all_hook({name, {module, func_name}}, context) do
    case apply(module, func_name, [context]) do
      :ok -> {:ok, context}
      {:ok, %{} = new_context} -> {:ok, new_context}
      %{} = new_context -> {:ok, Map.merge(context, new_context)}
      keyword when is_list(keyword) -> {:ok, Map.merge(context, Map.new(keyword))}
      {:error, reason} -> {:error, before_all_error(name, "failed: #{inspect(reason)}")}
      other -> {:error, before_all_error(name, "returned invalid value: #{inspect(other)}")}
    end
  catch
    kind, reason ->
      {:error, before_all_error(name, Exception.format_banner(kind, reason))}
  end

  defp before_all_error(name, detail) do
    label = if name, do: ~s( "#{name}"), else: ""
    "BeforeAll hook#{label} #{detail}"
  end

  # --- Message sink internals ---
  #
  # `state.messages` is nil when the sink is disabled, otherwise a map of
  # the output path, the envelope list (reverse order), the id counter, the
  # static id maps, and per-test-case tracking used for skipped-step
  # synthesis and crash reconciliation.

  defp now, do: Cucumber.Messages.timestamp(System.system_time(:nanosecond))

  defp allocate_ids(state, n) do
    next_id = state.messages.next_id
    ids = Enum.map(next_id..(next_id + n - 1), &Integer.to_string/1)
    {ids, put_in(state, [:messages, :next_id], next_id + n)}
  end

  # Emits testRunStarted exactly once, after all static envelopes and before
  # any run-time envelope.
  defp ensure_run_started(%{messages: %{run_started_id: nil}} = state) do
    {[id], state} = allocate_ids(state, 1)

    state
    |> put_in([:messages, :run_started_id], id)
    |> append_envelopes([Cucumber.Messages.test_run_started(id, now())])
  end

  defp ensure_run_started(state), do: state

  defp append_envelopes(state, envelopes) do
    Enum.reduce(envelopes, state, fn envelope, state ->
      state
      |> track_envelope(envelope)
      |> update_in([:messages, :envelopes], &[envelope | &1])
    end)
  end

  # Tracks which planned test steps of each open test case have started and
  # finished, so close_test_case/4 can synthesize events for the rest. Each
  # planned step carries its match-derived status override: a step that
  # never runs is reported UNDEFINED/AMBIGUOUS when that's *why* it can
  # never pass, regardless of why the scenario stopped.
  defp track_envelope(state, %{testCase: %{id: id, testSteps: test_steps}}) do
    planned = Enum.map(test_steps, &{&1.id, match_status_override(&1)})
    put_in(state, [:messages, :cases, id], planned)
  end

  defp track_envelope(state, %{testCaseStarted: %{id: id, testCaseId: test_case_id}}) do
    tracking = %{test_case_id: test_case_id, started: MapSet.new(), finished: MapSet.new()}
    put_in(state, [:messages, :open_cases, id], tracking)
  end

  defp track_envelope(state, %{testStepStarted: %{testCaseStartedId: id, testStepId: step_id}}) do
    track_step(state, id, :started, step_id)
  end

  defp track_envelope(state, %{testStepFinished: %{testCaseStartedId: id, testStepId: step_id}}) do
    track_step(state, id, :finished, step_id)
  end

  defp track_envelope(state, _envelope), do: state

  defp track_step(state, case_started_id, key, step_id) do
    case state.messages.open_cases do
      %{^case_started_id => tracking} ->
        tracking = Map.update!(tracking, key, &MapSet.put(&1, step_id))
        put_in(state, [:messages, :open_cases, case_started_id], tracking)

      _closed_or_unknown ->
        state
    end
  end

  # A pickle step with no matching definition can only ever be UNDEFINED,
  # and one with several matches AMBIGUOUS — even when it is synthesized
  # because the scenario stopped earlier. Hook steps have no override.
  defp match_status_override(%{stepDefinitionIds: []}), do: :undefined
  defp match_status_override(%{stepDefinitionIds: [_, _ | _]}), do: :ambiguous
  defp match_status_override(_step), do: nil

  # Synthesizes skip events for the given planned step ids that never ran
  # (same synthesis close_test_case/4 uses, without closing the case).
  # Match-status overrides apply only to failed-ish stops: a scenario that
  # skipped itself reports everything after the skip as SKIPPED, even
  # steps that could never have matched.
  defp skip_unfinished(state, case_started_id, step_ids, outcome) do
    case Map.fetch(state.messages.open_cases, case_started_id) do
      :error ->
        state

      {:ok, tracking} ->
        overrides =
          case outcome do
            :failedish -> Map.new(Map.get(state.messages.cases, tracking.test_case_id, []))
            :skipped -> %{}
          end

        Enum.reduce(step_ids, state, fn step_id, state ->
          status = Map.get(overrides, step_id) || :skipped
          synthesize_step_events(state, case_started_id, step_id, tracking, status)
        end)
    end
  end

  defp close_test_case(state, case_started_id, skip_status, will_be_retried) do
    case Map.fetch(state.messages.open_cases, case_started_id) do
      :error ->
        # Already closed — flush-time reconciliation after a normal finish
        state

      {:ok, tracking} ->
        planned = Map.get(state.messages.cases, tracking.test_case_id, [])

        state =
          Enum.reduce(planned, state, fn {step_id, _override}, state ->
            synthesize_step_events(state, case_started_id, step_id, tracking, skip_status)
          end)

        finished = Cucumber.Messages.test_case_finished(case_started_id, now(), will_be_retried)

        state
        |> append_envelopes([finished])
        |> update_in([:messages, :open_cases], &Map.delete(&1, case_started_id))
    end
  end

  # A planned step that never ran gets a started/finished pair with
  # `skip_status`; a step that started but never finished (the test process
  # died mid-step) gets an UNKNOWN finish.
  defp synthesize_step_events(state, case_started_id, step_id, tracking, skip_status) do
    cond do
      MapSet.member?(tracking.finished, step_id) ->
        state

      MapSet.member?(tracking.started, step_id) ->
        result = Cucumber.Messages.test_step_result(:unknown, 0)
        finished = Cucumber.Messages.test_step_finished(case_started_id, step_id, result, now())
        append_envelopes(state, [finished])

      true ->
        result = Cucumber.Messages.test_step_result(skip_status, 0)

        append_envelopes(state, [
          Cucumber.Messages.test_step_started(case_started_id, step_id, now()),
          Cucumber.Messages.test_step_finished(case_started_id, step_id, result, now())
        ])
    end
  end

  defp run_hook_started(%{messages: nil} = state, _ref), do: {nil, state}

  defp run_hook_started(state, ref) do
    state = ensure_run_started(state)
    {[id], state} = allocate_ids(state, 1)
    hook_id = Map.get(state.messages.hook_ids, ref)
    run_started_id = state.messages.run_started_id
    envelope = Cucumber.Messages.test_run_hook_started(id, run_started_id, hook_id, now())
    {id, append_envelopes(state, [envelope])}
  end

  defp run_hook_finished(state, nil, _status, _duration), do: state
  defp run_hook_finished(%{messages: nil} = state, _id, _status, _duration), do: state

  defp run_hook_finished(state, started_id, status, duration) do
    result = Cucumber.Messages.test_step_result(status, duration)

    state =
      append_envelopes(state, [
        Cucumber.Messages.test_run_hook_finished(started_id, result, now())
      ])

    if status == :failed,
      do: put_in(state, [:messages, :run_hook_failed], true),
      else: state
  end

  defp write_messages(%{path: path, envelopes: envelopes}) do
    lines = envelopes |> Enum.reverse() |> Enum.map(&[Cucumber.Messages.encode!(&1), "\n"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, lines)
  end

  defp initial_state(run_id) do
    %{run_id: run_id, before_all: :not_run, after_all: [], attachments: [], messages: nil}
  end
end
