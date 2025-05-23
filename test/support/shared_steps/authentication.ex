defmodule SharedSteps.Authentication do
  @moduledoc """
  Shared authentication steps for use across multiple test modules.
  """
  use Cucumber.SharedSteps

  defstep "I am logged in as {string}", %{args: [username]} do
    {:ok, %{current_user: username, authenticated: true}}
  end

  defstep "I should be authenticated", context do
    assert context.authenticated == true
    context
  end

  defstep "I should see {string} as the current user", %{args: [expected_user]} = context do
    assert context.current_user == expected_user
    context
  end
end
