defmodule Cucumber.Hooks do
  @moduledoc """
  Provides hooks for setup and teardown in Cucumber tests.

  Hooks can be defined globally or filtered by tags. They are executed
  in the order they are defined, with Before hooks running in definition
  order and After hooks running in reverse order.

  ## Examples

      defmodule DatabaseSupport do
        use Cucumber.Hooks

        # Global before hook - runs for all scenarios
        before_scenario context do
          # Setup code
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
      end
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

  Can optionally be filtered by tag. The hook receives the test context
  and must return one of:

  - `{:ok, context}`
  - `:ok` (keeps context unchanged)
  - map (merged into context)
  - `{:error, reason}` (fails the scenario; steps and after hooks don't run)
  - `:skipped` / `{:skipped, reason}` (skips the whole scenario without
    failing it; remaining before hooks and all steps are skipped, after
    hooks still run)
  - `:pending` / `{:pending, message}` (like `:skipped`, but the scenario
    fails with `Cucumber.PendingStepError`)
  """
  defmacro before_scenario(context_var, do: block) do
    build_hook_ast(
      __CALLER__.module,
      :before_scenario,
      nil,
      :before_scenario_global,
      context_var,
      block
    )
  end

  defmacro before_scenario(tag, context_var, do: block) when is_binary(tag) do
    tag_name = tag |> String.trim_leading("@") |> String.downcase()
    func_name = :"before_scenario_#{tag_name}"
    build_hook_ast(__CALLER__.module, :before_scenario, tag, func_name, context_var, block)
  end

  @doc """
  Defines an after_scenario hook that runs after each scenario.

  Can optionally be filtered by tag. After hooks run in reverse order
  of definition. The hook receives the test context.
  """
  defmacro after_scenario(context_var, do: block) do
    build_hook_ast(
      __CALLER__.module,
      :after_scenario,
      nil,
      :after_scenario_global,
      context_var,
      block
    )
  end

  defmacro after_scenario(tag, context_var, do: block) when is_binary(tag) do
    tag_name = tag |> String.trim_leading("@") |> String.downcase()
    func_name = :"after_scenario_#{tag_name}"
    build_hook_ast(__CALLER__.module, :after_scenario, tag, func_name, context_var, block)
  end

  defp build_hook_ast(caller_module, hook_type, tag, func_name, context_var, block) do
    defined = Module.get_attribute(caller_module, :cucumber_hook_names) || []

    if func_name in defined do
      tag_info = if tag, do: " for tag #{tag}", else: ""
      raise CompileError, description: "Duplicate hook: #{func_name} already defined#{tag_info}"
    end

    Module.put_attribute(caller_module, :cucumber_hook_names, [func_name | defined])

    quote do
      def unquote(func_name)(unquote(context_var)), do: unquote(block)
      @cucumber_hooks {unquote(hook_type), unquote(tag), {__MODULE__, unquote(func_name)}}
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __cucumber_hooks__ do
        @cucumber_hooks |> Enum.reverse()
      end
    end
  end

  @type hook :: {:before_scenario | :after_scenario, String.t() | nil, {module(), atom()}}

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
  @spec filter_hooks([hook()], :before_scenario | :after_scenario, [String.t()]) :: [
          {module(), atom()}
        ]
  def filter_hooks(hooks, type, tags) do
    hooks
    |> Enum.filter(fn
      {^type, nil, _fun} ->
        # Global hooks always run
        true

      {^type, tag, _fun} ->
        # Handle both with and without @ prefix
        tag in tags or String.trim_leading(tag, "@") in tags

      _ ->
        false
    end)
    |> Enum.map(fn {_type, _tag, hook_ref} -> hook_ref end)
  end

  @doc false
  # `{:halted, status, reason}` is returned when a before hook signals
  # `:pending` or `:skipped`; remaining before hooks are not run (the runner
  # then skips the scenario's steps but still runs after hooks).
  @spec run_before_hooks([hook()], map(), [String.t()]) ::
          {:ok, map()} | {:error, term()} | {:halted, :pending | :skipped, String.t() | nil}
  def run_before_hooks(hooks, context, tags) do
    hooks
    |> filter_hooks(:before_scenario, tags)
    |> Enum.reduce({:ok, context}, fn
      _hook, {:error, _} = error ->
        error

      _hook, {:halted, _status, _reason} = halted ->
        halted

      {module, func_name}, {:ok, context} ->
        apply_before_hook(module, func_name, context)
    end)
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
  # itself skipped (CCK semantics); subsequent after hooks still run.
  @spec run_after_hooks([hook()], map(), [String.t()]) :: :ok
  def run_after_hooks(hooks, context, tags) do
    hooks
    |> filter_hooks(:after_scenario, tags)
    # After hooks run in reverse order
    |> Enum.reverse()
    |> Enum.each(fn {module, func_name} -> apply(module, func_name, [context]) end)
  end
end
