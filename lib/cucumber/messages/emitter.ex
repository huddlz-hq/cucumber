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
      scenario (`open_test_case/2` emits the `testCase` envelope),
      starts one attempt at a time (`start_attempt/2` emits
      `testCaseStarted`), brackets steps and scenario hooks with
      started/finished events, and closes each attempt
      (`close_test_case/2`).

  Every session function is nil-safe: when the sink is disabled the session
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
  # Opens a message session for one scenario: allocates ids for the test
  # case and every test step (matched before/after scenario hooks, then the
  # pickle's steps), emits the testCase envelope, and returns the session.
  # Returns nil when the sink is disabled.
  @spec open_test_case(map(), map()) :: map() | nil
  def open_test_case(scenario, exec) do
    case RunCoordinator.message_context() do
      nil ->
        nil

      context ->
        # The same resolved lists Cucumber.Hooks executes, so the
        # pre-allocated ids line up positionally with the around callback
        before_hooks = Cucumber.Hooks.before_scenario_hooks(exec.hooks, exec.tags)
        after_hooks = Cucumber.Hooks.after_scenario_hooks(exec.hooks, exec.tags)

        steps = scenario.background_steps ++ scenario.steps

        pickle_step_ids =
          Map.get(scenario, :background_step_ids, []) ++ Map.get(scenario, :step_ids, [])

        total = length(before_hooks) + length(steps) + length(after_hooks)
        [test_case_id | step_test_ids] = RunCoordinator.take_message_ids(total + 1)
        {before_ids, rest} = Enum.split(step_test_ids, length(before_hooks))
        {step_ids, after_ids} = Enum.split(rest, length(steps))

        test_steps =
          hook_test_steps(before_ids, before_hooks, context.hook_ids) ++
            pickle_test_steps(step_ids, steps, pickle_step_ids, context, exec) ++
            hook_test_steps(after_ids, after_hooks, context.hook_ids)

        envelope =
          Messages.test_case(
            test_case_id,
            Map.get(scenario, :pickle_id),
            test_steps,
            context.test_run_started_id
          )

        RunCoordinator.emit_runtime([envelope])

        %{
          test_case_id: test_case_id,
          case_started_id: nil,
          before_ids: before_ids,
          step_ids: step_ids,
          after_ids: after_ids
        }
    end
  end

  defp hook_test_steps(ids, hooks, hook_ids) do
    Enum.zip_with(ids, hooks, fn id, {_name, ref} ->
      %{id: id, hookId: Map.get(hook_ids, ref)}
    end)
  end

  defp pickle_test_steps(ids, steps, pickle_step_ids, context, exec) do
    [ids, steps, pickle_step_ids]
    |> Enum.zip_with(fn [id, step, pickle_step_id] ->
      definition_ids =
        exec.step_registry
        |> matching_definitions(step.text)
        |> Enum.map(&Map.fetch!(context.step_definition_ids, &1.position))

      %{id: id, pickleStepId: pickle_step_id, stepDefinitionIds: definition_ids}
    end)
  end

  # Every definition the step text matches — one, none, or all of an
  # ambiguous set (in definition order, so ids ascend)
  defp matching_definitions(step_registry, step_text) do
    case StepRegistry.match(step_registry, step_text) do
      {:ok, definition, _args} -> [definition]
      :undefined -> []
      {:ambiguous, matches} -> Enum.map(matches, fn {definition, _args} -> definition end)
    end
  end

  @doc false
  # Emits testCaseStarted for one attempt (0-based in the message, 1-based
  # in the runner) and stores its id in the session.
  @spec start_attempt(map() | nil, pos_integer()) :: map() | nil
  def start_attempt(nil, _attempt), do: nil

  def start_attempt(session, attempt) do
    [id] = RunCoordinator.take_message_ids(1)
    envelope = Messages.test_case_started(id, session.test_case_id, attempt - 1, now())
    RunCoordinator.emit_runtime([envelope])
    %{session | case_started_id: id}
  end

  @doc false
  # Closes the current attempt: any step still unexecuted is synthesized as
  # SKIPPED and testCaseFinished is emitted (with willBeRetried when a retry
  # follows).
  @spec close_test_case(map() | nil, boolean()) :: :ok
  def close_test_case(nil, _will_be_retried), do: :ok

  def close_test_case(session, will_be_retried) do
    RunCoordinator.finish_test_case(session.case_started_id, :skipped, will_be_retried)
  end

  @doc false
  # Synthesizes skip events for this attempt's unexecuted before-hook and
  # pickle steps. The runner calls this right before the after-scenario
  # hooks run, so skipped pickle steps precede the after-hook events in the
  # stream (reference ordering); the after-hook steps themselves are
  # excluded — their real events follow. `outcome` is how the scenario
  # stopped: after a `:failedish` stop, unmatched steps report
  # UNDEFINED/AMBIGUOUS instead of SKIPPED (CCK failedish semantics).
  @spec skip_unexecuted_steps(map() | nil, :skipped | :failedish) :: :ok
  def skip_unexecuted_steps(nil, _outcome), do: :ok

  def skip_unexecuted_steps(session, outcome) do
    RunCoordinator.skip_unfinished_steps(
      session.case_started_id,
      session.before_ids ++ session.step_ids,
      outcome
    )
  end

  @doc false
  # Builds the per-step message reference the runner threads into step
  # execution: ids plus the monotonic start time for duration.
  @spec step_message(map() | nil, String.t() | nil) :: map() | nil
  def step_message(nil, _test_step_id), do: nil
  def step_message(_session, nil), do: nil

  def step_message(session, test_step_id) do
    %{
      test_case_started_id: session.case_started_id,
      test_step_id: test_step_id,
      started_at: System.monotonic_time(:nanosecond)
    }
  end

  @doc false
  @spec step_id(map() | nil, non_neg_integer()) :: String.t() | nil
  def step_id(nil, _index), do: nil
  def step_id(session, index), do: Enum.at(session.step_ids, index)

  @doc false
  @spec step_started(map() | nil) :: :ok
  def step_started(nil), do: :ok

  def step_started(message) do
    RunCoordinator.emit_runtime([
      Messages.test_step_started(message.test_case_started_id, message.test_step_id, now())
    ])
  end

  @doc false
  @spec step_finished(map() | nil, Messages.status(), String.t() | nil) :: :ok
  def step_finished(message, status, error_message \\ nil)

  def step_finished(nil, _status, _error_message), do: :ok

  def step_finished(message, status, error_message) do
    duration = System.monotonic_time(:nanosecond) - message.started_at
    result = Messages.test_step_result(status, duration, error_message)

    RunCoordinator.emit_runtime([
      Messages.test_step_finished(
        message.test_case_started_id,
        message.test_step_id,
        result,
        now()
      )
    ])
  end

  @doc false
  # Builds the around-callback `Cucumber.Hooks` uses to bracket each
  # scenario hook of the given kind (:before or :after) with
  # testStepStarted/testStepFinished events, injecting the hook's own
  # message reference so attachments recorded inside it land on the hook's
  # test step. Returns nil (hooks then run unbracketed) when the session is
  # nil.
  @spec hook_around(map() | nil, :before | :after) :: Cucumber.Hooks.around() | nil
  def hook_around(nil, _kind), do: nil

  def hook_around(session, kind) do
    ids =
      case kind do
        :before -> session.before_ids
        :after -> session.after_ids
      end

    fn index, _name, hook_fun ->
      case step_message(session, Enum.at(ids, index)) do
        nil ->
          hook_fun.(%{})

        message ->
          step_started(message)
          run_bracketed_hook(message, hook_fun)
      end
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

  defp now, do: Messages.timestamp(System.system_time(:nanosecond))
end
