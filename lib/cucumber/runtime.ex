defmodule Cucumber.Runtime do
  @moduledoc false

  # Runtime execution of cucumber steps.
  #
  # This module handles the step execution lifecycle within a running test:
  #
  # 1. Each step's text is matched against the step registry to find a definition
  # 2. Cucumber Expressions are used to extract typed parameters from step text
  # 3. The step function is invoked with context containing extracted `args`,
  #    optional `datatable`, and optional `docstring`
  # 4. Step return values are processed to update the shared context:
  #    - `:ok` keeps context unchanged
  #    - A map is merged into context
  #    - A keyword list is converted to a map and merged
  #    - `{:ok, data}` unwraps and merges
  #    - `{:error, reason}` fails the step
  #    - `:pending` / `{:pending, message}` marks the step pending: remaining
  #      steps are skipped, after hooks run, and the scenario fails with
  #      `Cucumber.PendingStepError`
  #    - `:skipped` / `{:skipped, reason}` skips the rest of the scenario:
  #      remaining steps don't run, after hooks run, and the scenario does
  #      **not** fail (a one-line notice is printed instead)
  # 5. On failure, enhanced error messages are generated with step history,
  #    file locations, and formatted assertion details

  alias Cucumber.Messages.Emitter
  alias Cucumber.StepRegistry
  alias Cucumber.StepRegistry.Definition
  alias Cucumber.TestCase

  @doc """
  Runs a complete scenario inside the test process: before hooks, background
  steps, scenario steps, and after hooks.

  Generated feature tests call this as their entire body. The runtime owning
  the whole lifecycle (rather than splitting it across ExUnit `setup` and
  `on_exit`) keeps after-hooks in the test process and gives the runner
  control over cross-step flow — the foundation for skip/pending semantics,
  retry, and event emission.

  Semantics:

    * a `{:error, reason}` from a before hook fails the scenario without
      running any steps (after hooks do not run)
    * a failing background step fails the scenario; after hooks do not run
      (they are only armed once the background succeeded)
    * after hooks run whether the scenario's steps pass or fail, receiving
      the post-background context
    * a `:pending` or `:skipped` signal (from a before hook, a background
      step, or a scenario step) skips the remaining steps — the unexecuted
      steps land in the context under `:skipped_steps` — and after hooks
      still run. Skipped scenarios pass with a printed notice; pending
      scenarios fail with `Cucumber.PendingStepError`
    * a failing scenario is retried when a retry limit is configured
      (`config :cucumber, retry: n` or a `@retry-n` tag; a tag beats the
      config, and a scenario-level tag beats a feature-level one): each
      attempt re-runs before hooks, background, steps, and after hooks
      with a fresh context (carrying `:retry_attempt`, 1-based), and the
      scenario passes if any attempt passes. Undefined, ambiguous, and
      pending scenarios are never retried — they cannot succeed by
      repetition — and neither is a cached `before_all` failure

  Returns the final context.
  """
  @spec run_scenario(map(), map(), map()) :: map()
  def run_scenario(exunit_context, scenario, runtime_data) do
    %{step_registry: step_registry, hooks: hooks} = runtime_data

    all_tags = Enum.uniq(scenario.feature_tags ++ scenario.scenario_tags)

    # Hook selection and step matching happen once, here; every attempt
    # and the message session share the result. Step arguments are
    # converted when each step runs (parameter type transforms are user
    # code), so nothing in the test case runs user code.
    test_case = TestCase.new(scenario, step_registry, hooks, all_tags)

    exec = %{test_case: test_case}

    # Run-level setup happens lazily before the first scenario of the run —
    # and before this scenario's message session opens, so testRunHook
    # events precede any testCase envelope in the stream. A cached error is
    # raised per attempt in run_single_attempt/4.
    exec = Map.put(exec, :before_all, Cucumber.RunCoordinator.before_all_context(hooks))

    # Cucumber Messages session (nil unless messages are on):
    # emits the testCase envelope now, per-attempt/per-step events later
    exec = Map.put(exec, :msg, Emitter.open_test_case(test_case))

    attempt_scenario(exunit_context, scenario, exec, 1, max_attempts(scenario))
  end

  # One full scenario lifecycle per attempt, with a fresh context each time.
  # Each attempt gets its own testCaseStarted message; the session must be
  # bound before do_attempt/5 so its catch clause can close the test case
  # (an implicit try only sees function arguments, not body bindings).
  defp attempt_scenario(exunit_context, scenario, exec, attempt, max_attempts) do
    exec = %{exec | msg: Emitter.start_attempt(exec.msg, attempt)}
    do_attempt(exunit_context, scenario, exec, attempt, max_attempts)
  end

  # A retryable failure within the attempt limit prints a flake warning and
  # re-runs; everything else propagates as usual. `catch` rather than
  # `rescue`: exits (e.g. a GenServer.call timeout) and throws are common
  # flake shapes and must retry too — ExUnit fails a test on all three
  # classes alike.
  defp do_attempt(exunit_context, scenario, exec, attempt, max_attempts) do
    context = run_single_attempt(exunit_context, scenario, exec, attempt)
    Emitter.close_test_case(exec.msg, false)
    context
  catch
    kind, reason ->
      retrying = attempt < max_attempts and retryable?(kind, reason, __STACKTRACE__)
      Emitter.close_test_case(exec.msg, retrying)

      if retrying do
        IO.puts(
          "Cucumber: retrying scenario \"#{scenario.scenario_name}\" " <>
            "(#{scenario.feature_file}:#{scenario.scenario_line}) — " <>
            "attempt #{attempt} of #{max_attempts} failed"
        )

        attempt_scenario(exunit_context, scenario, exec, attempt + 1, max_attempts)
      else
        :erlang.raise(kind, reason, __STACKTRACE__)
      end
  end

  defp retryable?(:error, reason, stacktrace) do
    retryable_error?(Exception.normalize(:error, reason, stacktrace))
  end

  # Exits and throws are runtime turbulence (timeouts, crashed processes) —
  # exactly the failure shapes retry exists for.
  defp retryable?(_kind, _reason, _stacktrace), do: true

  # Retrying can only help failures that might not repeat. Undefined,
  # ambiguous, and pending scenarios are deterministic — CCK semantics say
  # they run exactly once regardless of the retry limit — and a before_all
  # failure is cached for the whole run, so repeating it can't succeed either.
  defp retryable_error?(%Cucumber.PendingStepError{}), do: false
  defp retryable_error?(%Cucumber.AmbiguousStepError{}), do: false
  defp retryable_error?(%Cucumber.BeforeAllError{}), do: false
  defp retryable_error?(%Cucumber.StepError{failure_reason: :missing_step_definition}), do: false
  defp retryable_error?(_error), do: true

  # Attempts = retries + 1. A @retry-n tag overrides the :retry application
  # config, and a scenario-level tag beats a feature-level one — so a
  # scenario's @retry-0 exempts it from a feature-wide retry tag. Tags are
  # read from the compiler's scenario spec rather than the ExUnit context:
  # feature tags become @moduletag, so in the context the two levels are
  # indistinguishable.
  defp max_attempts(scenario) do
    retries =
      tag_retry_limit(scenario.scenario_tags) ||
        tag_retry_limit(scenario.feature_tags) ||
        config_retry_limit()

    max(retries, 0) + 1
  end

  defp config_retry_limit do
    case Application.get_env(:cucumber, :retry, 0) do
      nil ->
        0

      retries when is_integer(retries) ->
        retries

      other ->
        raise ArgumentError,
              "config :cucumber, :retry must be an integer, got: #{inspect(other)}"
    end
  end

  defp tag_retry_limit(tags) do
    Enum.find_value(tags, fn tag ->
      case Regex.run(~r/^retry-(\d+)$/, tag) do
        [_, n] -> String.to_integer(n)
        nil -> nil
      end
    end)
  end

  defp run_single_attempt(exunit_context, scenario, exec, attempt) do
    # :cucumber_phase tracks where in the lifecycle the context currently
    # is — attachments use it for attribution (see Cucumber.attach/4);
    # :cucumber_message_ref carries the current attempt's testCaseStarted id
    # so attachments recorded from hooks land in the message stream
    context =
      Map.merge(exunit_context, %{
        step_history: [],
        feature_file: scenario.feature_file,
        feature_tags: scenario.feature_tags,
        scenario_tags: scenario.scenario_tags,
        async: scenario.async,
        scenario_name: scenario.scenario_name,
        scenario_line: scenario.scenario_line,
        cucumber_phase: :before_scenario,
        cucumber_message_ref: message_ref(exec.msg),
        retry_attempt: attempt
      })

    # The before_all result (computed once in run_scenario/3, before the
    # message session opened) reaches every scenario; a failure fails every
    # scenario before any scenario hook or step runs.
    context =
      case exec.before_all do
        {:ok, before_all_context} -> Map.merge(context, before_all_context)
        {:error, message} -> raise Cucumber.BeforeAllError, message
      end

    test_case = exec.test_case

    case Cucumber.Hooks.run_before_hooks(
           test_case.before_hooks,
           context,
           Emitter.hook_around(exec.msg)
         ) do
      {:error, reason, hook_name} ->
        raise "Before hook#{hook_label(hook_name)} failed: #{inspect(reason)}"

      {:halted, status, reason} ->
        # Pending/skipped from a before hook: every step (background and
        # scenario) is skipped, but after hooks still run — CCK
        # hooks-skipped semantics.
        with_after_hooks(exec, context, fn ->
          context
          |> put_skipped_steps(test_case.pickle_test_steps)
          |> halt_scenario(status, reason, :before_hook, scenario)
        end)

      {:ok, context} ->
        run_background(scenario, context, exec)
    end
  end

  defp run_background(scenario, context, exec) do
    {background, scenario_steps} =
      Enum.split_with(exec.test_case.pickle_test_steps, & &1.background?)

    case execute_steps(background, context, exec) do
      {:halted, status, reason, step, remaining, context} ->
        # Pending/skipped is a deliberate signal, not a crash, so —
        # unlike a *failing* background step — after hooks run.
        with_after_hooks(exec, context, fn ->
          context
          |> put_skipped_steps(remaining ++ scenario_steps)
          |> halt_scenario(status, reason, {:step, step}, scenario)
        end)

      {:ok, context} ->
        run_scenario_steps(scenario, scenario_steps, context, exec)
    end
  end

  defp run_scenario_steps(scenario, scenario_steps, context, exec) do
    with_after_hooks(exec, context, fn ->
      case execute_steps(scenario_steps, context, exec) do
        {:ok, context} ->
          context

        {:halted, status, reason, step, remaining, context} ->
          context
          |> put_skipped_steps(remaining)
          |> halt_scenario(status, reason, {:step, step}, scenario)
      end
    end)
  end

  # :skipped_steps holds the unexecuted steps as Gherkin.Step structs
  defp put_skipped_steps(context, pickle_test_steps) do
    Map.put(context, :skipped_steps, Enum.map(pickle_test_steps, & &1.step))
  end

  defp with_after_hooks(exec, context, fun) do
    result =
      try do
        {:ok, fun.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    # Unexecuted pickle steps get their skip events now, so they precede
    # the after-hook events in the message stream (reference ordering).
    # How the scenario stopped decides their status (CCK failedish
    # semantics): after a deliberate skip — the only non-raising early
    # stop — everything is SKIPPED; after a failed-ish stop (failure,
    # pending, undefined, ambiguous), unmatched steps keep their
    # UNDEFINED/AMBIGUOUS status.
    outcome =
      case result do
        {:ok, _context} -> :skipped
        {:raised, _kind, _reason, _stacktrace} -> :failedish
      end

    Emitter.skip_unexecuted_steps(exec.msg, outcome)

    Cucumber.Hooks.run_after_hooks(
      exec.test_case.after_hooks,
      Map.put(context, :cucumber_phase, :after_scenario),
      Emitter.hook_around(exec.msg)
    )

    case result do
      {:ok, context} -> context
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  # A skipped scenario is not a failure: print a one-line notice and let the
  # test pass (ExUnit has no runtime-skip API, so the run's summary counts it
  # as passed). Pending is unfinished work and fails the scenario.
  defp halt_scenario(context, :skipped, reason, _source, scenario) do
    suffix = if reason, do: " — #{reason}", else: ""

    IO.puts(
      "Cucumber: skipped scenario \"#{scenario.scenario_name}\" " <>
        "(#{scenario.feature_file}:#{scenario.scenario_line})#{suffix}"
    )

    context
  end

  defp halt_scenario(context, :pending, reason, source, scenario) do
    error =
      Cucumber.PendingStepError.new(source, reason, scenario.feature_file, scenario.scenario_name)

    stacktrace =
      case source do
        {:step, step} -> scenario_stacktrace(context, step, current_stacktrace())
        :before_hook -> current_stacktrace()
      end

    :erlang.raise(:error, error, stacktrace)
  end

  # Runs pickle test steps in order until one halts; a halt returns the halting
  # Gherkin step and the pickle test steps that never ran.
  defp execute_steps(pickle_test_steps, context, exec) do
    pickle_test_steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, context}, fn {pickle_test_step, index}, {:ok, ctx} ->
      case do_execute_step(ctx, pickle_test_step, exec) do
        {:halted, status, reason, ctx} ->
          {:halt,
           {:halted, status, reason, pickle_test_step.step,
            Enum.drop(pickle_test_steps, index + 1), ctx}}

        ctx when is_map(ctx) ->
          {:cont, {:ok, ctx}}
      end
    end)
  end

  @doc """
  Executes a step with the given context and step registry.

  Returns the updated context, or `{:halted, status, reason, context}` when
  the step signaled `:pending` or `:skipped` — the caller owns what happens
  to the rest of the scenario.

  Step hooks do not run through this entry point; they require the scenario
  runner's hook list (see `run_scenario/3`).
  """
  @spec execute_step(map(), Gherkin.Step.t(), StepRegistry.t()) ::
          map() | {:halted, :pending | :skipped, String.t() | nil, map()}
  def execute_step(context, step, step_registry) do
    do_execute_step(
      context,
      TestCase.pickle_test_step(step, step_registry),
      %{test_case: %{before_step_hooks: [], after_step_hooks: []}, msg: nil}
    )
  end

  defp do_execute_step(context, %TestCase.PickleTestStep{step: step} = pickle_test_step, exec) do
    # Add step to history (ensure it exists first)
    context = Map.put_new(context, :step_history, [])
    context = update_in(context, [:step_history], &(&1 ++ [step]))
    context = Map.put(context, :cucumber_phase, :step)

    Emitter.report_step(exec.msg, pickle_test_step, fn overrides ->
      run_pickle_step(pickle_test_step.match, step, Map.merge(context, overrides), exec.test_case)
    end)
  end

  defp run_pickle_step(match, step, context, test_case) do
    case match do
      {:ok, definition} ->
        args = StepRegistry.args(definition, step.text)
        context = context |> prepare_context(args, step) |> Map.put(:step, step)
        run_matched_step(context, step, definition, test_case)

      {:ambiguous, definitions} ->
        feature_file = Map.get(context, :feature_file, "unknown")
        scenario_name = Map.get(context, :scenario_name, "unknown scenario")

        listed =
          for definition <- definitions do
            {Definition.display_pattern(definition), definition.module,
             %{function: definition.function, file: definition.file, line: definition.line}}
          end

        error = Cucumber.AmbiguousStepError.new(step, listed, feature_file, scenario_name)
        step_error(:ambiguous, error, scenario_stacktrace(context, step, current_stacktrace()))

      :undefined ->
        error = Cucumber.StepError.undefined(step, context)
        step_error(:undefined, error, scenario_stacktrace(context, step, current_stacktrace()))
    end
  end

  defp step_error(status, error, trace) do
    {status, Exception.message(error), {:raise, :error, error, trace}}
  end

  defp run_matched_step(context, step, definition, test_case) do
    case Cucumber.Hooks.run_before_step_hooks(test_case.before_step_hooks, context) do
      {:error, reason, hook_name} ->
        error =
          RuntimeError.exception(
            "Before step hook#{hook_label(hook_name)} failed: #{inspect(reason)}"
          )

        step_error(:failed, error, current_stacktrace())

      {:halted, status, reason} ->
        {status, reason, {:return, {:halted, status, reason, context}}}

      {:ok, context} ->
        invoke_step(context, step, definition, test_case.after_step_hooks)
    end
  end

  defp invoke_step(context, step, definition, after_hooks) do
    result = apply(definition.module, definition.function, [context])
    process_step_result(result, context)
  catch
    kind, reason ->
      trace = __STACKTRACE__
      Cucumber.Hooks.run_after_step_hooks(after_hooks, context, :failed)

      error =
        Cucumber.StepError.execution_failure(
          step,
          context,
          Definition.display_pattern(definition),
          {kind, reason, trace},
          Cucumber.RunCoordinator.attachments()
        )

      {:failed, error.failure_reason,
       {:raise, :error, error, scenario_stacktrace(context, step, trace)}}
  else
    {:halted, status, reason, ctx} = outcome ->
      Cucumber.Hooks.run_after_step_hooks(after_hooks, ctx, status)
      {status, reason, {:return, outcome}}

    ctx ->
      Cucumber.Hooks.run_after_step_hooks(after_hooks, ctx, :passed)
      {:passed, nil, {:return, ctx}}
  end

  defp hook_label(nil), do: ""
  defp hook_label(name), do: ~s( "#{name}")

  # The scenario-level attachment reference: hooks attach against the test
  # case only (no step id). Emitter supplies the active test step’s reference.
  defp message_ref(nil), do: nil
  defp message_ref(session), do: %{test_case_started_id: session.case_started_id}

  # Builds the stacktrace reported for a step failure: the first frame points
  # at the failing step's line in the feature file, followed by the original
  # trace (which leads with the step definition's own frame) minus this
  # module's internal frames.
  defp scenario_stacktrace(context, step, stacktrace) do
    test_module = Map.get(context, :module, Cucumber.Scenario)

    feature_file = Map.get(context, :feature_file, "unknown")

    feature_frame =
      {test_module, :scenario, 1, [file: String.to_charlist(feature_file), line: step.line + 1]}

    [feature_frame | Enum.reject(stacktrace, &match?({__MODULE__, _, _, _}, &1))]
  end

  defp current_stacktrace do
    {:current_stacktrace, trace} = Process.info(self(), :current_stacktrace)
    # Drop Process.info/2 and this function's own frames
    Enum.drop_while(trace, fn
      {Process, :info, _, _} -> true
      {__MODULE__, :current_stacktrace, _, _} -> true
      _frame -> false
    end)
  end

  defp prepare_context(context, args, step) do
    context
    |> Map.put(:args, args)
    |> add_datatable(step.datatable)
    |> add_docstring(step.docstring, step.docstring_media_type)
  end

  defp add_datatable(context, nil), do: context

  defp add_datatable(context, [headers | [_ | _] = rows] = datatable) do
    table_maps =
      Enum.map(rows, fn row ->
        headers |> Enum.zip(row) |> Map.new()
      end)

    table_data = %{headers: headers, rows: rows, maps: table_maps, raw: datatable}
    Map.put(context, :datatable, table_data)
  end

  defp add_datatable(context, datatable) do
    table_data = %{headers: [], rows: datatable, maps: [], raw: datatable}
    Map.put(context, :datatable, table_data)
  end

  defp add_docstring(context, nil, _media_type), do: context

  defp add_docstring(context, docstring, nil) do
    Map.put(context, :docstring, docstring)
  end

  defp add_docstring(context, docstring, media_type) do
    context
    |> Map.put(:docstring, docstring)
    |> Map.put(:docstring_media_type, media_type)
  end

  defp process_step_result(result, context) do
    case halt_signal(result) do
      {status, reason} -> {:halted, status, reason, context}
      nil -> merge_step_result(result, context)
    end
  end

  # A pending/skipped return is a control signal for the runner loop, not a
  # context update.
  defp halt_signal(:pending), do: {:pending, nil}
  defp halt_signal(:skipped), do: {:skipped, nil}
  defp halt_signal({:pending, message}) when is_binary(message), do: {:pending, message}
  defp halt_signal({:skipped, reason}) when is_binary(reason), do: {:skipped, reason}
  defp halt_signal(_result), do: nil

  defp merge_step_result(result, context) do
    case result do
      :ok ->
        context

      %{} = new_context ->
        Map.merge(context, new_context)

      keyword when is_list(keyword) ->
        Map.merge(context, Map.new(keyword))

      {:ok, data} when is_map(data) or is_list(data) ->
        process_step_result(data, context)

      {:error, reason} ->
        raise "Step failed: #{inspect(reason)}"

      other ->
        raise "Invalid step return value: #{inspect(other)}. " <>
                "Expected :ok, a map, a keyword list, {:ok, data}, " <>
                ":pending, {:pending, message}, :skipped, or {:skipped, reason}"
    end
  end
end
