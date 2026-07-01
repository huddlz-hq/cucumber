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
    * **Attachments** — `record_attachment/1` collects
      `Cucumber.Attachment` structs (see `Cucumber.attach/4`) in run order;
      `attachments/0` returns them.

  This process is also the future home of retry bookkeeping and the
  Cucumber Messages sink.
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
  # the failure-output formatting that follows.
  @spec record_attachment(Cucumber.Attachment.t()) :: :ok
  def record_attachment(%Cucumber.Attachment{} = attachment) do
    ensure_process()
    GenServer.call(__MODULE__, {:record_attachment, attachment})
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

  defp run_after_all_hook({name, {module, func_name}}, context) do
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
    result = execute_before_all(hooks)
    {:reply, result, %{state | before_all: result}}
  end

  def handle_call({:before_all, _hooks}, _from, state) do
    {:reply, state.before_all, state}
  end

  def handle_call({:register_after_all, hooks}, _from, state) do
    {:reply, :ok, %{state | after_all: hooks}}
  end

  def handle_call({:record_attachment, attachment}, _from, state) do
    {:reply, :ok, %{state | attachments: [attachment | state.attachments]}}
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
  # accumulating the merged context. The first error wins.
  defp execute_before_all(hooks) do
    {context, first_error} =
      Enum.reduce(hooks, {%{}, nil}, fn hook, {context, first_error} ->
        case run_before_all_hook(hook, context) do
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

  defp initial_state(run_id) do
    %{run_id: run_id, before_all: :not_run, after_all: [], attachments: []}
  end
end
