defmodule DatabaseExample do
  @moduledoc """
  Example database support for Cucumber tests.

  This demonstrates how to set up Ecto sandbox for tests that need it.
  In a real application, you would replace MyApp.Repo with your actual repo module.
  """
  use Cucumber.Hooks

  # Only runs for scenarios tagged with @database
  before_scenario "@database", context do
    # In a real app, you would do:
    # :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
    #
    # if context.async do
    #   Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
    # end

    # For this example, just add a marker
    {:ok, Map.put(context, :database_setup, true)}
  end

  # Cleanup after @database scenarios
  after_scenario "@database", _context do
    # In a real app with Ecto sandbox, cleanup is automatic
    # You might do other cleanup here if needed
    :ok
  end
end
