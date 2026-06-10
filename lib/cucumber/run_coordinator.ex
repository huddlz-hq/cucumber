defmodule Cucumber.RunCoordinator do
  @moduledoc """
  Run-wide coordination process for cucumber test runs.

  Started (or reset) by `Cucumber.compile_features!/1` — which runs from
  `test_helper.exs` before any test executes, so startup is race-free. State
  is keyed by a run id that changes on every `compile_features!` call, so
  repeated runs in one VM (`mix test.watch`, test harnesses) never see stale
  state.

  This process is deliberately the single home for run-scoped concerns as
  they land: BeforeAll/AfterAll once-guards, attachments, retry bookkeeping,
  and the Cucumber Messages sink.
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

  defp initial_state(run_id) do
    %{run_id: run_id}
  end
end
