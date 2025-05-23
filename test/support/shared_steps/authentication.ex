defmodule SharedSteps.Authentication do
  @moduledoc """
  Shared authentication steps for use across multiple test modules.
  """
  use Cucumber.SharedSteps

  defstep "I am logged in as {string}", context do
    username = List.first(context.args)
    {:ok, %{current_user: username, authenticated: true}}
  end

  defstep "I should be authenticated", context do
    assert context.authenticated == true
    context
  end

  defstep "I should see {string} as the current user", context do
    expected_user = List.first(context.args)
    assert context.current_user == expected_user
    context
  end
end
