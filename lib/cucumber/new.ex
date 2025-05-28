defmodule Cucumber.New do
  @moduledoc """
  Main entry point for the new auto-discovery cucumber system.

  Add to your test_helper.exs:

      Cucumber.New.compile_features!()
  """

  @doc """
  Discovers and compiles all cucumber features into ExUnit tests.

  Options:
    - :features - List of patterns for feature files
    - :steps - List of patterns for step definition files  
    - :support - List of patterns for support files
  """
  def compile_features!(opts \\ []) do
    modules = Cucumber.Compiler.compile_features!(opts)

    # Return the compiled module names for debugging
    modules
  end
end
