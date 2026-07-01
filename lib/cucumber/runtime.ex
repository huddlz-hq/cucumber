defmodule Cucumber.Runtime do
  @moduledoc """
  Runtime execution of cucumber steps.

  This module handles the step execution lifecycle within a running test:

  1. Each step's text is matched against the step registry to find a definition
  2. Cucumber Expressions are used to extract typed parameters from step text
  3. The step function is invoked with context containing extracted `args`,
     optional `datatable`, and optional `docstring`
  4. Step return values are processed to update the shared context:
     - `:ok` keeps context unchanged
     - A map is merged into context
     - A keyword list is converted to a map and merged
     - `{:ok, data}` unwraps and merges
     - `{:error, reason}` fails the step
     - `:pending` / `{:pending, message}` marks the step pending: remaining
       steps are skipped, after hooks run, and the scenario fails with
       `Cucumber.PendingStepError`
     - `:skipped` / `{:skipped, reason}` skips the rest of the scenario:
       remaining steps don't run, after hooks run, and the scenario does
       **not** fail (a one-line notice is printed instead)
  5. On failure, enhanced error messages are generated with step history,
     file locations, and formatted assertion details
  """

  alias Cucumber.Expression

  # Standard ExUnit context keys — everything else in the test context is a
  # scenario tag (ExUnit puts @tag values directly in the context as keys).
  @exunit_context_keys [
    :async,
    :line,
    :module,
    :registered,
    :file,
    :test,
    :describe,
    :describe_line,
    :test_type,
    :test_pid,
    :test_group
  ]

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
      (`config :cucumber, retry: n` or a `@retry-n` tag, tag winning):
      each attempt re-runs before hooks, background, steps, and after
      hooks with a fresh context (carrying `:retry_attempt`, 1-based), and
      the scenario passes if any attempt passes. Undefined, ambiguous, and
      pending scenarios are never retried — they cannot succeed by
      repetition

  Returns the final context.
  """
  @spec run_scenario(map(), map(), map()) :: map()
  def run_scenario(exunit_context, scenario, runtime_data) do
    %{step_registry: step_registry, hooks: hooks} = runtime_data
    parameter_types = Map.get(runtime_data, :parameter_types, %{})

    scenario_tags =
      exunit_context
      |> Map.keys()
      |> Enum.filter(&is_atom/1)
      |> Enum.reject(&(&1 in @exunit_context_keys))
      |> Enum.map(&to_string/1)

    # Combine feature tags + scenario tags for hook matching
    all_tags = Enum.uniq(scenario.feature_tags ++ scenario_tags)

    exec = %{
      step_registry: step_registry,
      parameter_types: parameter_types,
      hooks: hooks,
      tags: all_tags,
      scenario_tags: scenario_tags
    }

    attempt_scenario(exunit_context, scenario, exec, 1, max_attempts(all_tags))
  end

  # One full scenario lifecycle per attempt, with a fresh context each time.
  # A retryable failure within the attempt limit prints a flake warning and
  # re-runs; everything else propagates as usual.
  defp attempt_scenario(exunit_context, scenario, exec, attempt, max_attempts) do
    run_single_attempt(exunit_context, scenario, exec, attempt)
  rescue
    e ->
      if attempt < max_attempts and retryable?(e) do
        IO.puts(
          "Cucumber: retrying scenario \"#{scenario.scenario_name}\" " <>
            "(#{scenario.feature_file}:#{scenario.scenario_line}) — " <>
            "attempt #{attempt} of #{max_attempts} failed"
        )

        attempt_scenario(exunit_context, scenario, exec, attempt + 1, max_attempts)
      else
        reraise e, __STACKTRACE__
      end
  end

  # Retrying can only help failures that might not repeat. Undefined,
  # ambiguous, and pending scenarios are deterministic — CCK semantics say
  # they run exactly once regardless of the retry limit.
  defp retryable?(%Cucumber.PendingStepError{}), do: false
  defp retryable?(%Cucumber.AmbiguousStepError{}), do: false
  defp retryable?(%Cucumber.StepError{failure_reason: :missing_step_definition}), do: false
  defp retryable?(_error), do: true

  # Attempts = retries + 1. A @retry-n tag (scenario or feature level)
  # overrides the :retry application config.
  defp max_attempts(tags) do
    retries = tag_retry_limit(tags) || Application.get_env(:cucumber, :retry, 0)
    max(retries, 0) + 1
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
    # is — attachments use it for attribution (see Cucumber.attach/4)
    context =
      Map.merge(exunit_context, %{
        step_history: [],
        feature_file: scenario.feature_file,
        feature_tags: scenario.feature_tags,
        scenario_tags: exec.scenario_tags,
        async: scenario.async,
        scenario_name: scenario.scenario_name,
        scenario_line: scenario.scenario_line,
        cucumber_phase: :before_scenario,
        retry_attempt: attempt
      })

    # Run-level setup happens lazily before the first scenario of the run;
    # its context reaches every scenario. A BeforeAll failure fails every
    # scenario before any scenario hook or step runs.
    context =
      case Cucumber.RunCoordinator.before_all_context(exec.hooks) do
        {:ok, before_all_context} -> Map.merge(context, before_all_context)
        {:error, message} -> raise message
      end

    case Cucumber.Hooks.run_before_hooks(exec.hooks, context, exec.tags) do
      {:error, reason, hook_name} ->
        raise "Before hook#{hook_label(hook_name)} failed: #{inspect(reason)}"

      {:halted, status, reason} ->
        # Pending/skipped from a before hook: every step (background and
        # scenario) is skipped, but after hooks still run — CCK
        # hooks-skipped semantics.
        skipped = scenario.background_steps ++ scenario.steps

        with_after_hooks(exec, context, fn ->
          context
          |> Map.put(:skipped_steps, skipped)
          |> halt_scenario(status, reason, :before_hook, scenario)
        end)

      {:ok, context} ->
        run_background(scenario, context, exec)
    end
  end

  defp run_background(scenario, context, exec) do
    case execute_steps(scenario.background_steps, context, exec) do
      {:halted, status, reason, step, remaining, context} ->
        # Pending/skipped is a deliberate signal, not a crash, so —
        # unlike a *failing* background step — after hooks run.
        skipped = remaining ++ scenario.steps

        with_after_hooks(exec, context, fn ->
          context
          |> Map.put(:skipped_steps, skipped)
          |> halt_scenario(status, reason, {:step, step}, scenario)
        end)

      {:ok, context} ->
        run_scenario_steps(scenario, context, exec)
    end
  end

  defp run_scenario_steps(scenario, context, exec) do
    with_after_hooks(exec, context, fn ->
      case execute_steps(scenario.steps, context, exec) do
        {:ok, context} ->
          context

        {:halted, status, reason, step, remaining, context} ->
          context
          |> Map.put(:skipped_steps, remaining)
          |> halt_scenario(status, reason, {:step, step}, scenario)
      end
    end)
  end

  defp with_after_hooks(exec, context, fun) do
    fun.()
  after
    Cucumber.Hooks.run_after_hooks(
      exec.hooks,
      Map.put(context, :cucumber_phase, :after_scenario),
      exec.tags
    )
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

  defp execute_steps(steps, context, exec) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, context}, fn {step, index}, {:ok, ctx} ->
      case do_execute_step(ctx, step, exec) do
        {:halted, status, reason, ctx} ->
          {:halt, {:halted, status, reason, step, Enum.drop(steps, index + 1), ctx}}

        ctx when is_map(ctx) ->
          {:cont, {:ok, ctx}}
      end
    end)
  end

  @doc """
  Executes a step with the given context and step registry.

  `parameter_types` carries custom parameter type definitions (see
  `Cucumber.ParameterTypes`) used when matching cucumber expressions.

  Returns the updated context, or `{:halted, status, reason, context}` when
  the step signaled `:pending` or `:skipped` — the caller owns what happens
  to the rest of the scenario.

  Step hooks do not run through this entry point; they require the scenario
  runner's hook list (see `run_scenario/3`).
  """
  @spec execute_step(map(), Gherkin.Step.t(), map(), Expression.custom_types()) ::
          map() | {:halted, :pending | :skipped, String.t() | nil, map()}
  def execute_step(context, step, step_registry, parameter_types \\ %{}) do
    do_execute_step(context, step, %{
      step_registry: step_registry,
      parameter_types: parameter_types,
      hooks: [],
      tags: []
    })
  end

  defp do_execute_step(context, step, exec) do
    # Add step to history (ensure it exists first)
    context = Map.put_new(context, :step_history, [])
    context = update_in(context, [:step_history], &(&1 ++ [step]))
    context = Map.put(context, :cucumber_phase, :step)

    # Find matching step definition
    case find_step_definition(step.text, exec.step_registry, exec.parameter_types) do
      {:ok, {module, metadata}, args, pattern_text} ->
        # Prepare context with step arguments; :step is visible to step
        # hooks and the step body alike
        context =
          context
          |> prepare_context(args, step)
          |> Map.put(:step, step)

        run_matched_step(context, step, {module, metadata}, pattern_text, exec)

      {:ambiguous, matches} ->
        feature_file = Map.get(context, :feature_file, "unknown")
        scenario_name = Map.get(context, :scenario_name, "unknown scenario")

        listed =
          for {pattern_text, {module, metadata}, _args} <- matches,
              do: {pattern_text, module, metadata}

        error = Cucumber.AmbiguousStepError.new(step, listed, feature_file, scenario_name)
        :erlang.raise(:error, error, scenario_stacktrace(context, step, current_stacktrace()))

      :error ->
        # Extract context info for better error
        feature_file = Map.get(context, :feature_file, "unknown")
        scenario_name = Map.get(context, :scenario_name, "unknown scenario")
        step_history = Map.get(context, :step_history, [])

        # Use the enhanced error module
        error =
          Cucumber.StepError.missing_step_definition(
            step,
            feature_file,
            scenario_name,
            format_step_history_with_status(step_history, step, context)
          )

        :erlang.raise(:error, error, scenario_stacktrace(context, step, current_stacktrace()))
    end
  end

  # Brackets the matched step definition with before_step/after_step hooks.
  # A {:error, reason} from a before_step hook fails the scenario without
  # running the step body; a :pending/:skipped signal halts the scenario
  # like the step itself returning it.
  defp run_matched_step(context, step, definition, pattern_text, exec) do
    case Cucumber.Hooks.run_before_step_hooks(exec.hooks, context, exec.tags) do
      {:error, reason, hook_name} ->
        raise "Before step hook#{hook_label(hook_name)} failed: #{inspect(reason)}"

      {:halted, status, reason} ->
        {:halted, status, reason, context}

      {:ok, context} ->
        invoke_step(context, step, definition, pattern_text, exec)
    end
  end

  defp invoke_step(context, step, {module, metadata}, pattern_text, exec) do
    outcome =
      try do
        result = apply(module, metadata.function, [context])
        process_step_result(result, context)
      rescue
        e ->
          # After-step hooks see failing steps too (a hook raising here
          # masks the step's own error — that's the hook author's bug)
          Cucumber.Hooks.run_after_step_hooks(exec.hooks, context, exec.tags, :failed)

          # Extract meaningful information from the error
          feature_file = Map.get(context, :feature_file, "unknown")
          scenario_name = Map.get(context, :scenario_name, "unknown scenario")
          step_history = Map.get(context, :step_history, [])

          # Create enhanced error with better formatting
          enhanced_error =
            Cucumber.StepError.failed_step(
              step,
              pattern_text,
              format_exception_for_display(e),
              feature_file,
              scenario_name,
              format_step_history_with_status(step_history, step, context)
            )

          enhanced_error = append_attachments(enhanced_error, context)

          reraise enhanced_error, scenario_stacktrace(context, step, __STACKTRACE__)
      end

    {status, hook_context} =
      case outcome do
        {:halted, status, _reason, ctx} -> {status, ctx}
        ctx -> {:passed, ctx}
      end

    Cucumber.Hooks.run_after_step_hooks(exec.hooks, hook_context, exec.tags, status)
    outcome
  end

  defp hook_label(nil), do: ""
  defp hook_label(name), do: ~s( "#{name}")

  # Until Cucumber Messages land (#28), attachments surface in failure
  # output: a failing step's error lists everything the scenario attached.
  defp append_attachments(error, context) do
    scenario_attachments =
      Enum.filter(Cucumber.RunCoordinator.attachments(), fn attachment ->
        attachment.feature_file == Map.get(context, :feature_file) and
          attachment.scenario_name == Map.get(context, :scenario_name)
      end)

    case scenario_attachments do
      [] ->
        error

      attachments ->
        listing = Enum.map_join(attachments, "\n", &format_attachment/1)
        %{error | message: error.message <> "\n\nAttachments:\n\n" <> listing <> "\n"}
    end
  end

  defp format_attachment(%Cucumber.Attachment{} = attachment) do
    name = if attachment.filename, do: " (#{attachment.filename})", else: ""

    body =
      case attachment.encoding do
        :base64 -> "#{byte_size(Base.decode64!(attachment.body))} bytes, base64-encoded"
        :identity -> truncate(attachment.body, 200)
      end

    "  * #{attachment.media_type}#{name}: #{body}"
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp find_step_definition(step_text, step_registry, parameter_types) do
    matches =
      Enum.flat_map(step_registry, fn {key, definition} ->
        case match_pattern(key, step_text, parameter_types) do
          {:match, args} -> [{display_pattern(key), definition, args}]
          :no_match -> []
        end
      end)

    case matches do
      [] ->
        :error

      [{pattern_text, definition, args}] ->
        {:ok, definition, args, pattern_text}

      multiple ->
        # Stable listing order regardless of map iteration order
        {:ambiguous, Enum.sort_by(multiple, fn {pattern_text, _, _} -> pattern_text end)}
    end
  end

  defp match_pattern({:expression, pattern_text}, step_text, parameter_types) do
    # Compile pattern on the fly (cached via :persistent_term)
    Expression.match(step_text, Expression.compile(pattern_text, parameter_types))
  end

  defp match_pattern({:regex, {source, opts}}, step_text, _parameter_types) do
    # Cucumber regexes must match the entire step text. Captures become args
    # as strings (no type conversion — that's a cucumber-expressions feature);
    # unmatched optional groups become nil. The capture list is explicit
    # because PCRE silently drops *trailing* unmatched groups otherwise.
    {anchored, group_count} = anchored_regex(source, opts)
    capture_spec = if group_count == 0, do: [0], else: Enum.to_list(1..group_count)

    case :re.run(step_text, anchored.re_pattern, [{:capture, capture_spec, :index}]) do
      :nomatch ->
        :no_match

      {:match, _indexes} when group_count == 0 ->
        {:match, []}

      {:match, indexes} ->
        {:match, extract_group_values(indexes, step_text)}
    end
  end

  defp display_pattern({:expression, pattern_text}), do: pattern_text
  defp display_pattern({:regex, {source, opts}}), do: "~r/#{source}/#{opts}"

  # Wraps a regex so it must match the whole step text, mirroring how
  # Cucumber implementations treat regex step definitions. Author-supplied
  # ^/$ anchors still work inside the non-capturing group. The anchored
  # variant and its capture-group count are cached since steps are matched
  # on every execution.
  defp anchored_regex(source, opts) do
    cache_key = {__MODULE__, :anchored, source, opts}

    case :persistent_term.get(cache_key, :not_found) do
      :not_found ->
        anchored = Regex.compile!("\\A(?:#{source})\\z", opts)
        entry = {anchored, Expression.count_capture_groups(source)}
        :persistent_term.put(cache_key, entry)
        entry

      entry ->
        entry
    end
  end

  defp extract_group_values(indexes, step_text) do
    Enum.map(indexes, fn
      {-1, 0} -> nil
      {start, length} -> binary_part(step_text, start, length)
    end)
  end

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
    Enum.reject(trace, &match?({Process, _, _, _}, &1))
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

  defp format_exception_for_display(exception) do
    # Format the exception with enhanced readability
    case exception do
      %ExUnit.AssertionError{} = e ->
        format_assertion_error(e)

      %{__struct__: module} = e ->
        if assertion_error_module?(module),
          do: format_assertion_error(e),
          else: Exception.message(e)

      other ->
        inspect(other, pretty: true)
    end
  end

  defp assertion_error_module?(module) do
    module_str = Atom.to_string(module)
    String.ends_with?(module_str, "AssertionError") and Code.ensure_loaded?(module)
  end

  defp format_assertion_error(error) do
    # Extract the most useful parts of assertion errors
    base_message = Exception.message(error)

    # For PhoenixTest errors, enhance the formatting
    if String.contains?(base_message, "Found these elements") do
      lines = String.split(base_message, "\n")

      # Find where HTML elements start
      {before_html, html_and_after} =
        Enum.split_while(lines, fn line ->
          not (String.trim(line) |> String.starts_with?("<"))
        end)

      # Format the message parts
      formatted_before = Enum.join(before_html, "\n")

      # Group and format HTML elements
      formatted_html =
        html_and_after
        |> format_html_elements()
        |> Enum.join("\n")

      formatted_before <> "\n" <> formatted_html
    else
      base_message
    end
  end

  defp format_html_elements(lines) do
    lines
    |> group_html_elements()
    |> Enum.map(&format_single_html_element/1)
    |> Enum.reject(&(&1 == []))
  end

  defp group_html_elements(lines) do
    lines
    |> Enum.reduce({[], []}, &group_line/2)
    |> finalize_groups()
  end

  defp group_line(line, {groups, current}) do
    if html_line?(line) do
      {groups, current ++ [line]}
    else
      finalize_current_group(groups, current)
    end
  end

  defp finalize_current_group(groups, []), do: {groups, []}
  defp finalize_current_group(groups, current), do: {groups ++ [current], []}

  defp finalize_groups({groups, []}), do: groups
  defp finalize_groups({groups, current}), do: groups ++ [current]

  defp html_line?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "<") or String.ends_with?(trimmed, ">")
  end

  defp format_single_html_element(lines) do
    # Format a single HTML element with proper indentation
    lines
    |> Enum.map_join("\n", fn line ->
      "  " <> line
    end)
    # Add blank line after each element
    |> then(&[&1, ""])
  end

  defp format_step_history_with_status(step_history, current_step, context) do
    # Convert step history to include status and context
    step_history
    |> Enum.reverse()
    # Show last 10 steps to avoid clutter
    |> Enum.take(10)
    # Put them back in chronological order
    |> Enum.reverse()
    |> Enum.map(fn step ->
      status = if step == current_step, do: :failed, else: :passed
      {status, step, context}
    end)
  end
end
