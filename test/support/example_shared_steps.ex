defmodule ExampleSharedSteps do
  @moduledoc """
  Example shared steps module demonstrating Phase 1 functionality.

  This module shows that we can:
  - Use Cucumber.SharedSteps
  - Define steps with defstep
  - Have the module compile successfully
  """
  use Cucumber.SharedSteps

  defstep "a simple shared step" do
    %{shared_step_executed: true}
  end

  defstep "I have {int} items", context do
    count = List.first(context.args)
    {:ok, %{item_count: count}}
  end

  defstep "I log in as {string}", context do
    username = List.first(context.args)
    Map.put(context, :current_user, username)
  end
end
