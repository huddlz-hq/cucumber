defmodule Cucumber.Messages.Emitter do
  @moduledoc """
  Drives Cucumber Messages emission through the `Cucumber.RunCoordinator`
  sink.

  Two roles:

    * **Configuration** — the compiler prepares features before defining their tests.
      The deprecated `configure/6` also builds the run's static envelopes
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

  @doc false
  # ExUnit may start running an async feature as soon as its module is defined.
  # Return compilations only once all their static envelopes are registered.
  def prepare_features(features, registry, hooks, path) do
    prefix = if path, do: RunCoordinator.next_message_prefix(), else: ""

    {pairs, next_id} =
      Enum.map_reduce(features, 0, fn feature, id ->
        compilation = Gherkin.Pickles.compile(feature, id, prefix)
        {{feature, compilation}, compilation.next_id}
      end)

    if path, do: register(path, pairs, registry, hooks, next_id, prefix)
    pairs
  end

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
    register(path, features_with_compilations, step_registry, hooks, next_id, "")
  end

  defp register(path, features_with_compilations, step_registry, hooks, next_id, prefix) do
    feature_envelopes =
      Enum.flat_map(features_with_compilations, fn {feature, compilation} ->
        [
          Messages.source(feature.file, feature.source),
          Messages.gherkin_document(feature.file, compilation.document, compilation.comments)
          | Enum.map(compilation.pickles, &Messages.pickle/1)
        ]
      end)

    {step_definitions, next_id} = step_definition_envelopes(step_registry, next_id, prefix)
    {hook_envelopes, next_id} = hook_envelopes(hooks, next_id, prefix)

    {parameter_type_envelopes, next_id} =
      step_registry
      |> StepRegistry.parameter_types()
      |> parameter_type_envelopes(next_id, prefix)

    RunCoordinator.configure_messages(%{
      path: path,
      meta: Messages.meta(),
      features: feature_envelopes,
      step_definitions: step_definitions,
      hooks: hook_envelopes,
      parameter_types: parameter_type_envelopes,
      next_id: if(prefix == "", do: next_id, else: 0)
    })
  end

  # Definitions arrive in a stable (file, line) order, so their ids are
  # deterministic across runs. Each is keyed by its step function, which
  # identifies it across step registries.
  defp step_definition_envelopes(step_registry, next_id, prefix) do
    step_registry
    |> StepRegistry.definitions()
    |> Enum.map_reduce(next_id, fn definition, id ->
      envelope = Messages.step_definition(prefix <> Integer.to_string(id), definition)
      {{{definition.module, definition.function}, envelope}, id + 1}
    end)
  end

  defp hook_envelopes(hooks, next_id, prefix) do
    Enum.map_reduce(hooks, next_id, fn {type, tag, name, ref}, id ->
      {{ref, Messages.hook(prefix <> Integer.to_string(id), type, tag, name, hook_source(ref))},
       id + 1}
    end)
  end

  # Hook macros don't record their definition line; the module's compile
  # source at least names the file.
  defp hook_source({module, _func_name}) do
    case module.module_info(:compile)[:source] do
      nil -> %{}
      source -> %{uri: source |> to_string() |> Path.relative_to_cwd()}
    end
  end

  defp parameter_type_envelopes(parameter_types, next_id, prefix) do
    parameter_types
    |> Enum.sort_by(fn {name, _definition} -> name end)
    |> Enum.map_reduce(next_id, fn {name, definition}, id ->
      {{name, Messages.parameter_type(prefix <> Integer.to_string(id), definition)}, id + 1}
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

  @typep action ::
           {:return, term()} | {:raise, :error | :exit | :throw, term(), Exception.stacktrace()}
  @typep execute_step :: (map() -> {Messages.status(), String.t() | nil, action()})

  @doc false
  # A test step owns its attachment reference from its start through its last
  # after-step hook. A killed process leaves reconciliation to the recorder.
  @spec report_step(
          map() | nil,
          TestCase.HookStep.t() | TestCase.PickleTestStep.t(),
          execute_step()
        ) :: term()
  def report_step(nil, _test_step, run) do
    {_status, _detail, action} = run.(%{})
    complete_step(action)
  end

  def report_step(session, test_step, run) do
    attempt = session.case_started_id
    id = Map.fetch!(session.step_ids, test_step.position)
    ref = %{test_case_started_id: attempt, test_step_id: id}
    started_at = System.monotonic_time(:nanosecond)
    RunCoordinator.record_message({:step_started, attempt, id})

    {status, detail, action} =
      try do
        run.(%{cucumber_message_ref: ref})
      catch
        kind, reason ->
          {:failed, Exception.format_banner(kind, reason), {:raise, kind, reason, __STACKTRACE__}}
      end

    duration = System.monotonic_time(:nanosecond) - started_at
    RunCoordinator.record_message({:step_finished, attempt, id, status, duration, detail})
    complete_step(action)
  end

  defp complete_step({:return, value}), do: value
  defp complete_step({:raise, kind, reason, trace}), do: :erlang.raise(kind, reason, trace)

  @doc false
  @spec hook_around(map() | nil) :: Cucumber.Hooks.around() | nil
  def hook_around(nil), do: nil

  def hook_around(session) do
    fn hook, invoke ->
      report_step(session, hook, fn overrides ->
        result = invoke.(overrides)
        {status, detail} = hook_result(result)
        {status, detail, {:return, result}}
      end)
    end
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
