defmodule Cucumber.RunCoordinator do
  @moduledoc """
  Run-wide coordination process for cucumber test runs.

  Started by `Cucumber.compile_features!/1`. A run lasts until the
  `ExUnit.after_suite/1` callback ends it, so every `compile_features!` call
  made while a suite loads (from `test_helper.exs` or from test files) joins
  the same run, and the next suite in the same VM (`mix test.watch`) starts
  a fresh one. Test harnesses start a fresh run with `ensure_started/0`.

  Current run-scoped concerns:

    * **BeforeAll once-guard** — `before_all_context/1` runs the run's
      `before_all` hooks exactly once and caches the merged context (or the
      first error) for every subsequent scenario. Each distinct set of
      `before_all` hooks (one per `compile_features!` call's support
      modules) is guarded separately. The hooks execute in the
      first caller's process — never inside the coordinator, so a hook may
      call back into it (e.g. `Cucumber.attach/4`). The coordinator only
      grants that caller the run; concurrent callers (`@async` feature
      modules) wait for its result.
    * **AfterAll hand-off** — `register_after_all/1` collects the run's
      `after_all` hooks; the `ExUnit.after_suite/1` callback registered by
      the compiler claims them exactly once via `run_after_all/1`.
    * **Attachments** — `record_attachment/2` collects
      `Cucumber.Attachment` structs (see `Cucumber.attach/4`) in run order;
      `attachments/0` returns them.
    * **Cucumber Messages** — when `config :cucumber, messages: path` is
      set, each `compile_features!` call reserves message ids
      (`reserve_message_ids/1`) and hands the coordinator its static
      envelopes (`configure_messages/1`) before defining any test module,
      and the runner reports each run-time event as it happens
      (`record_message/1`). The coordinator holds the stream in a message
      recorder (`lib/cucumber/messages/recorder.ex`) and feeds it one event
      at a time, which is what keeps the stream ordered under `@async`
      features. The `after_suite` callback writes the NDJSON
      file (`flush_messages/1`). Note that `ExUnit.after_suite/1`
      callbacks fire on *every* `ExUnit.run/1` — the stream is written
      (and messages turn off) when the first run in the VM completes, so a
      project that invokes a nested `ExUnit.run/1` mid-suite with messages
      enabled gets the stream truncated at that point
      (`Cucumber.BehaviorCase` relies on exactly this per-run firing to
      capture streams in tests).
  """

  use GenServer

  alias Cucumber.Messages.Recorder

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

  @doc false
  # Starts the coordinator for a new run, or joins the run in progress (see
  # the moduledoc). Returns the run id.
  @spec start_or_join() :: integer()
  def start_or_join do
    run_id = :erlang.unique_integer([:positive])

    case GenServer.start(__MODULE__, run_id, name: __MODULE__) do
      {:ok, _pid} -> run_id
      {:error, {:already_started, _pid}} -> GenServer.call(__MODULE__, {:join, run_id})
    end
  end

  @doc false
  # Ends the run: the next start_or_join/0 starts a fresh one. Called by the
  # after_suite callback once the run's after_all hooks and messages are done.
  @spec end_run() :: :ok
  def end_run do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :end_run)
    end

    :ok
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
  # every module compiled by one compile_features! call carries the same
  # list, and each distinct list runs once per run.
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

        case GenServer.call(__MODULE__, {:claim_before_all, before_all_hooks}, :infinity) do
          :run ->
            result = execute_before_all(before_all_hooks)

            GenServer.call(
              __MODULE__,
              {:finish_before_all, before_all_hooks, result},
              :infinity
            )

            result

          {:done, result} ->
            result
        end
    end
  end

  @doc false
  # Adds after_all hooks to the run's, for the after_suite callback to claim.
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
  # current `:test_case_started_id`/`:test_step_id` (or nil) so the message
  # stream gets an `attachment` envelope in order.
  @spec record_attachment(Cucumber.Attachment.t(), map() | nil) :: :ok
  def record_attachment(%Cucumber.Attachment{} = attachment, message_ref \\ nil) do
    ensure_process()
    GenServer.call(__MODULE__, {:record_attachment, attachment, message_ref})
  end

  @doc false
  # Turns messages on for this run and takes `n` run-unique message ids for
  # a compile_features! call to assign its pickles, step definitions, hooks
  # and parameter types. Returns the first.
  @spec reserve_message_ids(non_neg_integer()) :: non_neg_integer()
  def reserve_message_ids(n) do
    ensure_process()
    GenServer.call(__MODULE__, {:reserve_message_ids, n})
  end

  @doc false
  # Turns messages on for this run and adds one compile_features! call's
  # static envelopes: `config` carries the output `:path` and the envelopes
  # (see Cucumber.Messages.Recorder.add_static/2).
  @spec configure_messages(map()) :: :ok
  def configure_messages(config) do
    ensure_process()
    GenServer.call(__MODULE__, {:configure_messages, config})
  end

  @doc false
  # Records one run-time message event (see Cucumber.Messages.Recorder)
  # and returns the recorder's reply — nil when messages are off or the
  # coordinator isn't running.
  @spec record_message(Recorder.event()) :: term()
  def record_message(event) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:record_message, event})
    end
  end

  @doc false
  # Ends the message stream and writes it to the configured NDJSON path,
  # then turns messages off. No-op when messages are off.
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

        results =
          for hook <- Enum.reverse(after_all_hooks),
              do: bracket_run_hook(hook, context, &run_after_all_hook/2)

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil ->
            :ok

          {:error, %{kind: kind, reason: reason, stacktrace: stacktrace}} ->
            :erlang.raise(kind, reason, stacktrace)
        end
    end
  end

  # An after_all hook's context is not handed on, so it passes with the
  # context it was given. Its error is the raise to replay once every
  # after_all hook has run.
  defp run_after_all_hook({name, {module, func_name}}, context) do
    case apply(module, func_name, [context]) do
      {:error, reason} ->
        {:error, %{kind: :error, reason: after_all_error(name, reason), stacktrace: []}}

      _other ->
        {:ok, context}
    end
  catch
    kind, reason ->
      {:error, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__}}
  end

  # The result of running one run-level hook: it passed with the context it
  # hands on, or failed with an error whose shape the hook kind defines.
  @typep run_hook_result :: {:ok, map()} | {:error, term()}

  # Runs one run-level hook via `run_hook.(hook, context)`, bracketed with
  # testRunHookStarted/Finished envelopes through the coordinator.
  #
  # The hook's own context carries its testRunHookStarted id as the message
  # ref, so attachments it records (Cucumber.attach/4) land on the hook in
  # the message stream. The ref is stripped from the context the hook hands
  # on, so it never leaks into the next hook or a scenario.
  @spec bracket_run_hook(
          {term(), {module(), atom()}},
          map(),
          ({term(), {module(), atom()}}, map() -> run_hook_result())
        ) :: run_hook_result()
  defp bracket_run_hook({_name, ref} = hook, context, run_hook) do
    started_id = run_hook_started_call(ref)
    started_at = System.monotonic_time(:nanosecond)
    hook_context = if started_id, do: put_run_hook_ref(context, started_id), else: context

    {status, result} =
      case run_hook.(hook, hook_context) do
        {:ok, context} -> {:passed, {:ok, Map.delete(context, :cucumber_message_ref)}}
        {:error, _error} = error -> {:failed, error}
      end

    run_hook_finished_call(started_id, status, System.monotonic_time(:nanosecond) - started_at)
    result
  end

  defp put_run_hook_ref(context, started_id),
    do: Map.put(context, :cucumber_message_ref, %{test_run_hook_started_id: started_id})

  # Run-level hooks run in a caller's process (never inside the coordinator),
  # so their testRunHook events go through GenServer calls.
  defp run_hook_started_call(ref), do: record_message({:run_hook_started, ref})

  defp run_hook_finished_call(nil, _status, _duration), do: :ok

  defp run_hook_finished_call(started_id, status, duration) do
    record_message({:run_hook_finished, started_id, status, duration})
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

  def handle_call({:join, _run_id}, _from, %{live: true} = state) do
    {:reply, state.run_id, state}
  end

  def handle_call({:join, run_id}, _from, _state) do
    {:reply, run_id, initial_state(run_id)}
  end

  def handle_call(:end_run, _from, state) do
    {:reply, :ok, %{state | live: false}}
  end

  def handle_call(:run_id, _from, state) do
    {:reply, state.run_id, state}
  end

  # The first claimant of a set of before_all hooks runs them in its own
  # process; later claimants wait (no reply) until it finishes. The runner
  # is monitored so waiters are released with an error if it dies mid-hook.
  def handle_call({:claim_before_all, key}, {pid, _tag} = from, state) do
    case Map.get(state.before_all, key) do
      nil ->
        running = %{pid: pid, monitor: Process.monitor(pid), waiters: []}
        {:reply, :run, put_in(state.before_all[key], {:running, running})}

      {:running, running} ->
        running = %{running | waiters: [from | running.waiters]}
        {:noreply, put_in(state.before_all[key], {:running, running})}

      result ->
        {:reply, {:done, result}, state}
    end
  end

  def handle_call({:finish_before_all, key, result}, {pid, _tag}, state) do
    case Map.get(state.before_all, key) do
      {:running, %{pid: ^pid} = running} ->
        Process.demonitor(running.monitor, [:flush])
        {:reply, :ok, complete_before_all(state, key, running, result)}

      # A stale finish (the run was reset while the hooks ran) is ignored.
      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:register_after_all, hooks}, _from, state) do
    {:reply, :ok, %{state | after_all: Enum.uniq(state.after_all ++ hooks)}}
  end

  def handle_call({:record_attachment, attachment, message_ref}, _from, state) do
    {_reply, state} = record(state, {:attachment, attachment, message_ref})
    {:reply, :ok, %{state | attachments: [attachment | state.attachments]}}
  end

  def handle_call({:reserve_message_ids, n}, _from, state) do
    {start_id, recorder} = state |> messages_on() |> Recorder.reserve_ids(n)
    {:reply, start_id, %{state | recorder: recorder}}
  end

  def handle_call({:configure_messages, config}, _from, state) do
    recorder = state |> messages_on() |> Recorder.add_static(Map.delete(config, :path))

    {:reply, :ok,
     %{state | recorder: recorder, messages_path: state.messages_path || config.path}}
  end

  def handle_call({:record_message, event}, _from, state) do
    {reply, state} = record(state, event)
    {:reply, reply, state}
  end

  def handle_call({:flush_messages, suite_result}, _from, state) do
    if Recorder.enabled?(state.recorder) and state.messages_path do
      {:ok, state} = record(state, {:finish_run, Map.get(suite_result, :failures, 0) == 0})
      write_messages(state.messages_path, state.recorder)
    end

    {:reply, :ok, %{state | recorder: Recorder.disabled(), messages_path: nil}}
  end

  def handle_call(:attachments, _from, state) do
    {:reply, Enum.reverse(state.attachments), state}
  end

  def handle_call(:take_after_all, _from, state) do
    before_all_context =
      for {_key, {:ok, context}} <- state.before_all, reduce: %{} do
        merged -> Map.merge(merged, context)
      end

    {:reply, {state.after_all, before_all_context}, %{state | after_all: []}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    running =
      Enum.find(state.before_all, fn
        {_key, {:running, %{monitor: ^monitor}}} -> true
        _other -> false
      end)

    case running do
      {key, {:running, running}} ->
        error = before_all_error(nil, "process exited: #{Exception.format_exit(reason)}")
        {:noreply, complete_before_all(state, key, running, {:error, error})}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp complete_before_all(state, key, running, result) do
    Enum.each(running.waiters, &GenServer.reply(&1, {:done, result}))
    put_in(state.before_all[key], result)
  end

  # Runs every before_all hook in definition order — even after one fails —
  # accumulating the merged context. The first error wins. Runs in the
  # claiming caller's process; each hook is bracketed with
  # testRunHookStarted/Finished envelopes through the coordinator.
  defp execute_before_all(hooks) do
    {context, first_error} =
      Enum.reduce(hooks, {%{}, nil}, fn hook, {context, first_error} ->
        case bracket_run_hook(hook, context, &run_before_all_hook/2) do
          {:ok, context} -> {context, first_error}
          {:error, error} -> {context, first_error || error}
        end
      end)

    if first_error, do: {:error, first_error}, else: {:ok, context}
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

  defp messages_on(%{recorder: recorder}) do
    if Recorder.enabled?(recorder), do: recorder, else: Recorder.new()
  end

  defp record(state, event) do
    {reply, recorder} = Recorder.record(state.recorder, event, System.system_time(:nanosecond))
    {reply, %{state | recorder: recorder}}
  end

  defp write_messages(path, recorder) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Recorder.to_ndjson(recorder))
  end

  defp initial_state(run_id) do
    %{
      run_id: run_id,
      live: true,
      before_all: %{},
      after_all: [],
      attachments: [],
      recorder: Recorder.disabled(),
      messages_path: nil
    }
  end
end
