defmodule Cucumber.Hooks do
  @moduledoc """
  Provides hooks for setup and teardown in Cucumber tests.

  Four levels of hooks are supported, mirroring reference Cucumber
  implementations:

    * `before_all`/`after_all` — run once per test run (see below)
    * `before_scenario`/`after_scenario` — run around each scenario
    * `before_step`/`after_step` — run around each step (including
      background steps)

  Scenario and step hooks can be filtered by tag. Hooks of the same kind
  run in the order they are defined (module order, then definition order),
  with after-hooks running in reverse. Any hook can be given a `name:`,
  which appears in failure output (and in Cucumber Messages, eventually).

  ## Examples

      defmodule DatabaseSupport do
        use Cucumber.Hooks

        # Runs once before the first scenario of the run
        before_all context do
          {:ok, Map.put(context, :api_started, true)}
        end

        # Runs once after the whole run, in reverse definition order
        after_all _context do
          :ok
        end

        # Global before hook - runs for all scenarios
        before_scenario context, name: "prepare database" do
          {:ok, Map.put(context, :setup, true)}
        end

        # Tagged before hook - only runs for @database scenarios
        before_scenario "@database", context do
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)

          if context.async do
            Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
          end

          {:ok, context}
        end

        # After hooks run in reverse order
        after_scenario _context do
          # Cleanup code
          :ok
        end

        # Step hooks bracket every step; after_step sees the step's status
        after_step context do
          log_step(context.step, context.step_status)
          :ok
        end
      end

  ## Run-level hooks

  `before_all` hooks run lazily, exactly once per run, before the first
  scenario that executes (serialized through `Cucumber.RunCoordinator`, so
  this is safe with `@async` features). Their accumulated context map is
  merged into every scenario's context. If a `before_all` hook fails, the
  remaining `before_all` hooks still run (to set up as much as possible for
  cleanup), but every scenario in the run fails with the original error.

  `after_all` hooks run once after the whole suite via `ExUnit.after_suite/1`,
  in reverse definition order, receiving the `before_all` context plus the
  ExUnit suite summary under `:suite_result`. A failing `after_all` hook
  fails the run; the remaining `after_all` hooks still run.

  Run-level hooks cannot be tagged (they don't belong to any scenario).

  ## One hook per kind — unless named

  A module may define only one *global* and one *per-tag* hook of each kind;
  giving hooks a `name:` lifts that restriction, so a module can define any
  number of distinctly-named hooks of the same kind.
  """

  defmacro __using__(_opts) do
    quote do
      import Cucumber.Hooks
      Module.register_attribute(__MODULE__, :cucumber_hooks, accumulate: true)
      @before_compile Cucumber.Hooks
    end
  end

  @doc """
  Defines a before_scenario hook that runs before each scenario.

  Can optionally be filtered by tag and/or given a `name:`. The hook
  receives the test context and must return one of:

  - `{:ok, context}`
  - `:ok` (keeps context unchanged)
  - map (merged into context)
  - keyword list (merged into context)
  - `{:error, reason}` (fails the scenario; steps and after hooks don't run)
  - `:skipped` / `{:skipped, reason}` (skips the whole scenario without
    failing it; remaining before hooks and all steps are skipped, after
    hooks still run)
  - `:pending` / `{:pending, message}` (like `:skipped`, but the scenario
    fails with `Cucumber.PendingStepError`)
  """
  defmacro before_scenario(context_var, do: block) do
    build_hook_ast(__CALLER__.module, :before_scenario, nil, nil, context_var, block)
  end

  defmacro before_scenario(tag, context_var, do: block) when is_binary(tag) do
    build_hook_ast(__CALLER__.module, :before_scenario, tag, nil, context_var, block)
  end

  defmacro before_scenario(context_var, opts, do: block) when is_list(opts) do
    build_hook_ast(__CALLER__.module, :before_scenario, nil, opts[:name], context_var, block)
  end

  defmacro before_scenario(tag, context_var, opts, do: block)
           when is_binary(tag) and is_list(opts) do
    build_hook_ast(__CALLER__.module, :before_scenario, tag, opts[:name], context_var, block)
  end

  @doc """
  Defines an after_scenario hook that runs after each scenario.

  Can optionally be filtered by tag and/or given a `name:`. After hooks run
  in reverse order of definition and receive the post-background context.
  Their return values are ignored.
  """
  defmacro after_scenario(context_var, do: block) do
    build_hook_ast(__CALLER__.module, :after_scenario, nil, nil, context_var, block)
  end

  defmacro after_scenario(tag, context_var, do: block) when is_binary(tag) do
    build_hook_ast(__CALLER__.module, :after_scenario, tag, nil, context_var, block)
  end

  defmacro after_scenario(context_var, opts, do: block) when is_list(opts) do
    build_hook_ast(__CALLER__.module, :after_scenario, nil, opts[:name], context_var, block)
  end

  defmacro after_scenario(tag, context_var, opts, do: block)
           when is_binary(tag) and is_list(opts) do
    build_hook_ast(__CALLER__.module, :after_scenario, tag, opts[:name], context_var, block)
  end

  @doc """
  Defines a before_step hook that runs before each step (including
  background steps) of matching scenarios.

  Can optionally be filtered by tag and/or given a `name:`. The hook
  receives the step's prepared context — including `:step` (the
  `Gherkin.Step`), `:args`, and any `:datatable`/`:docstring` — and supports
  the same return values as `before_scenario` (a `:skipped`/`:pending`
  signal skips the rest of the scenario; `{:error, reason}` fails it
  without running the step body).
  """
  defmacro before_step(context_var, do: block) do
    build_hook_ast(__CALLER__.module, :before_step, nil, nil, context_var, block)
  end

  defmacro before_step(tag, context_var, do: block) when is_binary(tag) do
    build_hook_ast(__CALLER__.module, :before_step, tag, nil, context_var, block)
  end

  defmacro before_step(context_var, opts, do: block) when is_list(opts) do
    build_hook_ast(__CALLER__.module, :before_step, nil, opts[:name], context_var, block)
  end

  defmacro before_step(tag, context_var, opts, do: block)
           when is_binary(tag) and is_list(opts) do
    build_hook_ast(__CALLER__.module, :before_step, tag, opts[:name], context_var, block)
  end

  @doc """
  Defines an after_step hook that runs after each step (including failing
  ones) of matching scenarios.

  Can optionally be filtered by tag and/or given a `name:`. The hook
  receives the step's context with `:step_status` set to `:passed`,
  `:failed`, `:pending`, or `:skipped`. After-step hooks run in reverse
  order of definition; their return values are ignored.
  """
  defmacro after_step(context_var, do: block) do
    build_hook_ast(__CALLER__.module, :after_step, nil, nil, context_var, block)
  end

  defmacro after_step(tag, context_var, do: block) when is_binary(tag) do
    build_hook_ast(__CALLER__.module, :after_step, tag, nil, context_var, block)
  end

  defmacro after_step(context_var, opts, do: block) when is_list(opts) do
    build_hook_ast(__CALLER__.module, :after_step, nil, opts[:name], context_var, block)
  end

  defmacro after_step(tag, context_var, opts, do: block)
           when is_binary(tag) and is_list(opts) do
    build_hook_ast(__CALLER__.module, :after_step, tag, opts[:name], context_var, block)
  end

  @doc """
  Defines a before_all hook that runs once per test run, before the first
  scenario that executes.

  The hook receives the accumulated before_all context (starting from an
  empty map) and may return `:ok`, a map, a keyword list, `{:ok, map}`, or
  `{:error, reason}`. The final context map is merged into every scenario's
  context. Cannot be tagged; can be given a `name:`.
  """
  defmacro before_all(context_var, do: block) do
    build_hook_ast(__CALLER__.module, :before_all, nil, nil, context_var, block)
  end

  defmacro before_all(context_var, opts, do: block) when is_list(opts) do
    build_hook_ast(__CALLER__.module, :before_all, nil, opts[:name], context_var, block)
  end

  @doc """
  Defines an after_all hook that runs once after the whole test run, in
  reverse definition order.

  The hook receives the before_all context with the ExUnit suite summary
  merged under `:suite_result`. A raise or `{:error, reason}` fails the
  run, but the remaining after_all hooks still run. Cannot be tagged; can
  be given a `name:`.
  """
  defmacro after_all(context_var, do: block) do
    build_hook_ast(__CALLER__.module, :after_all, nil, nil, context_var, block)
  end

  defmacro after_all(context_var, opts, do: block) when is_list(opts) do
    build_hook_ast(__CALLER__.module, :after_all, nil, opts[:name], context_var, block)
  end

  defp build_hook_ast(caller_module, hook_type, tag, name, context_var, block) do
    validate_name!(hook_type, name)
    func_name = hook_func_name(hook_type, tag, name)
    defined = Module.get_attribute(caller_module, :cucumber_hook_names) || []

    if func_name in defined do
      raise CompileError,
        description:
          "Duplicate hook: #{func_name} already defined#{duplicate_hint(tag, name)}. " <>
            "Give hooks a distinct name: to define several #{hook_type} hooks in one module."
    end

    Module.put_attribute(caller_module, :cucumber_hook_names, [func_name | defined])

    quote do
      def unquote(func_name)(unquote(context_var)), do: unquote(block)

      @cucumber_hooks {unquote(hook_type), unquote(tag), unquote(name),
                       {__MODULE__, unquote(func_name)}}
    end
  end

  defp validate_name!(hook_type, name) do
    unless is_nil(name) or (is_binary(name) and name != "") do
      raise CompileError,
        description:
          "Hook name for #{hook_type} must be a non-empty string, got: #{inspect(name)}"
    end
  end

  defp hook_func_name(type, nil, nil), do: :"#{type}_global"
  defp hook_func_name(type, tag, nil), do: :"#{type}_#{slug(String.trim_leading(tag, "@"))}"
  defp hook_func_name(type, _tag, name), do: :"#{type}_named_#{slug(name)}"

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp duplicate_hint(tag, name) do
    cond do
      name -> " for name #{inspect(name)}"
      tag -> " for tag #{tag}"
      true -> ""
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __cucumber_hooks__ do
        @cucumber_hooks |> Enum.reverse()
      end
    end
  end

  @type hook_type ::
          :before_scenario
          | :after_scenario
          | :before_step
          | :after_step
          | :before_all
          | :after_all

  @type hook :: {hook_type(), String.t() | nil, String.t() | nil, {module(), atom()}}

  @doc false
  @spec collect_hooks([module()]) :: [hook()]
  def collect_hooks(modules) do
    modules
    |> Enum.flat_map(fn module ->
      if function_exported?(module, :__cucumber_hooks__, 0) do
        module.__cucumber_hooks__()
      else
        []
      end
    end)
  end

  @doc false
  @spec filter_hooks([hook()], hook_type(), [String.t()]) :: [
          {String.t() | nil, {module(), atom()}}
        ]
  def filter_hooks(hooks, type, tags) do
    hooks
    |> Enum.filter(fn
      {^type, nil, _name, _fun} ->
        # Global hooks always run
        true

      {^type, tag, _name, _fun} ->
        # Handle both with and without @ prefix
        tag in tags or String.trim_leading(tag, "@") in tags

      _ ->
        false
    end)
    |> Enum.map(fn {_type, _tag, name, hook_ref} -> {name, hook_ref} end)
  end

  @typedoc """
  Wraps each hook invocation — receives the hook's run-order index, its
  name (nil if unnamed), and a one-arity function that executes the hook
  with the given context overrides merged in; must return that function's
  result. The scenario runner uses this to bracket hooks with Cucumber
  Messages events and to inject each hook's message reference.
  """
  @type around :: (non_neg_integer(), String.t() | nil, (map() -> term()) -> term())

  @doc false
  # The before_scenario hooks that will run for `tags`, in run order.
  # Single source of truth shared with the message emitter, which
  # pre-allocates test-step ids positionally against this list.
  @spec before_scenario_hooks([hook()], [String.t()]) :: [
          {String.t() | nil, {module(), atom()}}
        ]
  def before_scenario_hooks(hooks, tags) do
    filter_hooks(hooks, :before_scenario, tags)
  end

  @doc false
  # The after_scenario hooks that will run for `tags`, in run order (i.e.
  # reverse definition order). Same contract as before_scenario_hooks/2.
  @spec after_scenario_hooks([hook()], [String.t()]) :: [
          {String.t() | nil, {module(), atom()}}
        ]
  def after_scenario_hooks(hooks, tags) do
    hooks
    |> filter_hooks(:after_scenario, tags)
    |> Enum.reverse()
  end

  @doc false
  # `{:halted, status, reason}` is returned when a before hook signals
  # `:pending` or `:skipped`; remaining before hooks are not run (the runner
  # then skips the scenario's steps but still runs after hooks).
  # `{:error, reason, name}` carries the failing hook's name (nil if unnamed)
  # for error reporting.
  @spec run_before_hooks([hook()], map(), [String.t()], around() | nil) ::
          {:ok, map()}
          | {:error, term(), String.t() | nil}
          | {:halted, :pending | :skipped, String.t() | nil}
  def run_before_hooks(hooks, context, tags, around \\ nil) do
    hooks
    |> before_scenario_hooks(tags)
    |> run_halting_hooks(context, around || (&unwrapped/3))
  end

  @doc false
  # Same contract as run_before_hooks/4, for before_step hooks.
  @spec run_before_step_hooks([hook()], map(), [String.t()]) ::
          {:ok, map()}
          | {:error, term(), String.t() | nil}
          | {:halted, :pending | :skipped, String.t() | nil}
  def run_before_step_hooks(hooks, context, tags) do
    hooks
    |> filter_hooks(:before_step, tags)
    |> run_halting_hooks(context, &unwrapped/3)
  end

  defp unwrapped(_index, _name, hook_fun), do: hook_fun.(%{})

  defp run_halting_hooks(filtered_hooks, context, around) do
    filtered_hooks
    |> Enum.with_index()
    |> Enum.reduce({:ok, context}, fn
      _hook, {:error, _, _} = error ->
        error

      _hook, {:halted, _status, _reason} = halted ->
        halted

      {{name, hook_ref}, index}, {:ok, context} ->
        invoke_halting_hook(around, index, name, hook_ref, context)
    end)
  end

  defp invoke_halting_hook(around, index, name, {module, func_name}, context) do
    run = fn overrides -> apply_before_hook(module, func_name, Map.merge(context, overrides)) end

    case around.(index, name, run) do
      {:error, reason} -> {:error, reason, name}
      other -> other
    end
  end

  defp apply_before_hook(module, func_name, context) do
    result = apply(module, func_name, [context])

    case halt_signal(result) do
      {status, reason} -> {:halted, status, reason}
      nil -> merge_hook_result(result, context, module, func_name)
    end
  end

  # A pending/skipped return from a before hook is a control signal: the
  # scenario's steps are skipped, after hooks still run.
  defp halt_signal(:pending), do: {:pending, nil}
  defp halt_signal(:skipped), do: {:skipped, nil}
  defp halt_signal({:pending, message}) when is_binary(message), do: {:pending, message}
  defp halt_signal({:skipped, reason}) when is_binary(reason), do: {:skipped, reason}
  defp halt_signal(_result), do: nil

  defp merge_hook_result(result, context, module, func_name) do
    case result do
      :ok ->
        {:ok, context}

      {:ok, new_context} ->
        {:ok, new_context}

      %{} = new_context ->
        {:ok, Map.merge(context, new_context)}

      keyword when is_list(keyword) ->
        {:ok, Map.merge(context, Map.new(keyword))}

      {:error, _} = error ->
        error

      other ->
        raise "Invalid hook return value from #{inspect(module)}.#{func_name}/1: #{inspect(other)}. " <>
                "Expected :ok, {:ok, context}, a map, a keyword list, {:error, reason}, " <>
                ":pending, {:pending, message}, :skipped, or {:skipped, reason}"
    end
  end

  @doc false
  # Return values are ignored — an after hook returning :skipped only marks
  # itself skipped (CCK semantics); subsequent after hooks still run. The
  # around callback receives run-order indexes (i.e. reverse definition
  # order).
  @spec run_after_hooks([hook()], map(), [String.t()], around() | nil) :: :ok
  def run_after_hooks(hooks, context, tags, around \\ nil) do
    around = around || (&unwrapped/3)

    hooks
    |> after_scenario_hooks(tags)
    |> Enum.with_index()
    |> Enum.each(fn {{name, {module, func_name}}, index} ->
      around.(index, name, fn overrides ->
        apply(module, func_name, [Map.merge(context, overrides)])
      end)
    end)
  end

  @doc false
  # Runs after_step hooks in reverse order with :step_status set in the
  # context. Return values are ignored.
  @spec run_after_step_hooks([hook()], map(), [String.t()], atom()) :: :ok
  def run_after_step_hooks(hooks, context, tags, status) do
    context = Map.put(context, :step_status, status)

    hooks
    |> filter_hooks(:after_step, tags)
    |> Enum.reverse()
    |> Enum.each(fn {_name, {module, func_name}} -> apply(module, func_name, [context]) end)
  end
end
