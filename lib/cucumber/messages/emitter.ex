defmodule Cucumber.Messages.Emitter do
  @moduledoc """
  Drives Cucumber Messages emission through the `Cucumber.RunCoordinator`
  sink.

  Two roles:

    * **Configuration** — `configure/6` (deprecated) builds the run's static envelopes
      (meta, sources, gherkin documents, pickles, step definitions, hooks,
      parameter types) plus the id maps run-time messages reference, and
      hands them to the coordinator. Called by
      `Cucumber.compile_features!/1` when
      `config :cucumber, messages: path` is set.
    * **Run-time sessions** — the scenario runner opens a session per
      scenario, starts one attempt at a time, brackets steps and scenario
      hooks with started/finished events, and closes each attempt. Each
      becomes an event recorded through the coordinator, which decides
      what the stream says.

  Every session function is nil-safe: when messages are off the session
  is nil and all of this is a no-op, so the runner carries no conditionals.

  > #### Deprecated {: .warning}
  >
  > This module is driven by the compiler and will become internal in 2.0.
  > Enable Cucumber Messages with `config :cucumber, messages: path`
  > instead of calling it directly.
  """

  alias Cucumber.Messages
  alias Cucumber.RunCoordinator
  alias Cucumber.StepRegistry
  alias Cucumber.TestCase

  @doc """
  Builds the run's static envelopes and id maps and configures the
  coordinator's message sink.

  `features_with_compilations` pairs each discovered feature with its
  `Gherkin.Pickles.Compilation`; `next_id` continues the compilation id
  sequence so every id in the stream is run-unique.

  `step_registry` is the `Cucumber.StepRegistry` discovery builds; it
  carries the run's parameter types, so `parameter_types` is ignored.
  """
  @deprecated "Configure messages with `config :cucumber, messages: path`; removed in 2.0"
  @spec configure(
          String.t(),
          [{map(), Gherkin.Pickles.Compilation.t()}],
          StepRegistry.t(),
          [tuple()],
          map(),
          non_neg_integer()
        ) :: :ok
  def configure(path, features_with_compilations, step_registry, hooks, _parameter_types, next_id) do
    configure(path, features_with_compilations, step_registry, hooks, next_id)
  end

  @doc false
  # Called by Cucumber.Compiler. The registry carries the parameter types.
  @spec configure(
          String.t(),
          [{map(), Gherkin.Pickles.Compilation.t()}],
          StepRegistry.t(),
          [tuple()],
          non_neg_integer()
        ) ::
          :ok
  def configure(path, features_with_compilations, step_registry, hooks, next_id) do
    feature_envelopes =
      Enum.flat_map(features_with_compilations, fn {feature, compilation} ->
        [
          Messages.source(feature.file, feature.source),
          Messages.gherkin_document(feature.file, compilation.document, compilation.comments)
          | Enum.map(compilation.pickles, &Messages.pickle/1)
        ]
      end)

    {step_definition_envelopes, step_definition_ids, next_id} =
      step_definition_envelopes(step_registry, next_id)

    {hook_envelopes, hook_ids, next_id} = hook_envelopes(hooks, next_id)

    {parameter_type_envelopes, next_id} =
      step_registry
      |> StepRegistry.parameter_types()
      |> parameter_type_envelopes(next_id)

    envelopes =
      [Messages.meta() | feature_envelopes] ++
        step_definition_envelopes ++ hook_envelopes ++ parameter_type_envelopes

    RunCoordinator.configure_messages(%{
      path: path,
      envelopes: envelopes,
      next_id: next_id,
      step_definition_ids: step_definition_ids,
      hook_ids: hook_ids
    })
  end

  # Definitions arrive in a stable (file, line) order, so their ids are
  # deterministic across runs. Ids are keyed by the definition's position.
  defp step_definition_envelopes(step_registry, next_id) do
    definitions = StepRegistry.definitions(step_registry)
    count = length(definitions)
    ids = Enum.map(next_id..(next_id + count - 1)//1, &Integer.to_string/1)

    envelopes = Enum.zip_with(ids, definitions, &Messages.step_definition/2)
    ids_by_position = Map.new(Enum.zip(Enum.map(definitions, & &1.position), ids))

    {envelopes, ids_by_position, next_id + count}
  end

  defp hook_envelopes(hooks, next_id) do
    hooks
    |> Enum.reduce({[], %{}, next_id}, fn {type, tag, name, ref}, {envelopes, ids, id} ->
      envelope = Messages.hook(Integer.to_string(id), type, tag, name, hook_source(ref))
      {[envelope | envelopes], Map.put(ids, ref, Integer.to_string(id)), id + 1}
    end)
    |> then(fn {envelopes, ids, id} -> {Enum.reverse(envelopes), ids, id} end)
  end

  # Hook macros don't record their definition line; the module's compile
  # source at least names the file.
  defp hook_source({module, _func_name}) do
    case module.module_info(:compile)[:source] do
      nil -> %{}
      source -> %{uri: source |> to_string() |> Path.relative_to_cwd()}
    end
  end

  defp parameter_type_envelopes(parameter_types, next_id) do
    parameter_types
    |> Enum.sort_by(fn {name, _definition} -> name end)
    |> Enum.map_reduce(next_id, fn {_name, definition}, id ->
      {Messages.parameter_type(Integer.to_string(id), definition), id + 1}
    end)
  end

  @doc false
  # Opens a message session for one test case: the recorder allocates ids
  # for the test case and every test step and emits the testCase envelope.
  # Returns nil when messages are off, so a run without them makes no
  # further coordinator calls.
  @spec open_test_case(TestCase.t()) :: map() | nil
  def open_test_case(%TestCase{} = test_case) do
    case RunCoordinator.record_message({:open_test_case, test_case}) do
      nil ->
        nil

      %{test_case_id: test_case_id, step_ids: step_ids} ->
        %{test_case_id: test_case_id, case_started_id: nil, step_ids: step_ids}
    end
  end

  @doc false
  # Starts one attempt (1-based) and stores its testCaseStarted id in the
  # session.
  @spec start_attempt(map() | nil, pos_integer()) :: map() | nil
  def start_attempt(nil, _attempt), do: nil

  def start_attempt(session, attempt) do
    id = RunCoordinator.record_message({:start_attempt, session.test_case_id, attempt})
    %{session | case_started_id: id}
  end

  @doc false
  # Closes the current attempt (with willBeRetried when a retry follows);
  # steps that never ran are reported first.
  @spec close_test_case(map() | nil, boolean()) :: :ok
  def close_test_case(nil, _will_be_retried), do: :ok

  def close_test_case(session, will_be_retried) do
    RunCoordinator.record_message({:close_attempt, session.case_started_id, will_be_retried})
    :ok
  end

  @doc false
  # Reports this attempt's before-hook and pickle steps that never ran.
  # The runner calls this right before the after-scenario hooks, so they
  # precede the after-hook events in the stream. `outcome` is how the
  # scenario stopped: `:skipped` or `:failedish`.
  @spec skip_unexecuted_steps(map() | nil, :skipped | :failedish) :: :ok
  def skip_unexecuted_steps(nil, _outcome), do: :ok

  def skip_unexecuted_steps(session, outcome) do
    RunCoordinator.record_message({:skip_unexecuted, session.case_started_id, outcome})
    :ok
  end

  @doc false
  # Builds the per-step message reference the runner threads into a test
  # step's execution: ids plus the monotonic start time for duration.
  @spec step_message(map() | nil, TestCase.HookStep.t() | TestCase.PickleTestStep.t()) ::
          map() | nil
  def step_message(nil, _test_step), do: nil

  def step_message(session, test_step) do
    %{
      test_case_started_id: session.case_started_id,
      test_step_id: Map.fetch!(session.step_ids, test_step.position),
      started_at: System.monotonic_time(:nanosecond)
    }
  end

  @doc false
  @spec step_started(map() | nil) :: :ok
  def step_started(nil), do: :ok

  def step_started(message) do
    RunCoordinator.record_message(
      {:step_started, message.test_case_started_id, message.test_step_id}
    )

    :ok
  end

  @doc false
  @spec step_finished(map() | nil, Messages.status(), String.t() | nil) :: :ok
  def step_finished(message, status, error_message \\ nil)

  def step_finished(nil, _status, _error_message), do: :ok

  def step_finished(message, status, error_message) do
    duration = System.monotonic_time(:nanosecond) - message.started_at

    RunCoordinator.record_message(
      {:step_finished, message.test_case_started_id, message.test_step_id, status, duration,
       error_message}
    )

    :ok
  end

  @doc false
  # Builds the around-callback `Cucumber.Hooks` uses to bracket each
  # scenario hook with testStepStarted/testStepFinished events, injecting
  # the hook's own message reference so attachments recorded inside it land
  # on the hook's test step. Returns nil (hooks then run unbracketed) when
  # the session is nil.
  @spec hook_around(map() | nil) :: Cucumber.Hooks.around() | nil
  def hook_around(nil), do: nil

  def hook_around(session) do
    fn hook_step, hook_fun ->
      message = step_message(session, hook_step)
      step_started(message)
      run_bracketed_hook(message, hook_fun)
    end
  end

  defp run_bracketed_hook(message, hook_fun) do
    overrides = %{
      cucumber_message_ref: %{
        test_case_started_id: message.test_case_started_id,
        test_step_id: message.test_step_id
      }
    }

    result = hook_fun.(overrides)
    {status, status_message} = hook_result(result)
    step_finished(message, status, status_message)
    result
  catch
    kind, reason ->
      step_finished(message, :failed, Exception.format_banner(kind, reason))
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Before-hook results arrive as control tuples ({:halted, ...} from the
  # hooks module, {:error, ...} verbatim); after-hook results are raw return
  # values — including bare :skipped/:pending signals, which per CCK
  # semantics mark only the hook itself. Anything else counts as passed.
  defp hook_result({:halted, status, reason}), do: {status, reason}
  defp hook_result({:error, reason}), do: {:failed, inspect(reason)}
  defp hook_result(:pending), do: {:pending, nil}
  defp hook_result(:skipped), do: {:skipped, nil}
  defp hook_result({:pending, message}) when is_binary(message), do: {:pending, message}
  defp hook_result({:skipped, reason}) when is_binary(reason), do: {:skipped, reason}
  defp hook_result(_result), do: {:passed, nil}
end
