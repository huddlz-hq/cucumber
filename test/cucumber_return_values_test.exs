defmodule CucumberReturnValuesTest do
  use Cucumber, feature: "return_values.feature"

  # Initialize context with a marker
  defstep "initial context is empty", context do
    Map.put(context, :initial, true)
  end

  # Test returning a map directly
  defstep "I return a map directly with value {string}", %{args: [value]} do
    %{direct_value: value}
  end

  # Test returning the :ok atom
  defstep "I return an :ok atom", _context do
    :ok
  end

  # Test returning {:ok, map} tuple
  defstep "I return a tuple with value {string}", %{args: [value]} do
    {:ok, %{tuple_value: value}}
  end

  # Test returning nil
  defstep "I return nil explicitly", _context do
    nil
  end

  # Verify direct map return
  defstep "I should see value {string} in the context", %{args: [value]} = context do

    cond do
      # Check for direct map return value
      Map.has_key?(context, :direct_value) ->
        assert context.direct_value == value

      # Check for {:ok, map} tuple return value
      Map.has_key?(context, :tuple_value) ->
        assert context.tuple_value == value

      true ->
        flunk("Expected value #{value} not found in context")
    end

    context
  end

  # Verify context preservation with :ok or nil returns
  defstep "the initial context should be preserved", context do
    assert context.initial == true

    # Only check that our custom key exists and no other custom keys were added
    # (ignoring standard ExUnit keys which will always be present, and our new step_history tracking)
    custom_keys =
      Map.keys(context) --
        [
          :initial,
          :args,
          :step_history,
          :feature_file,
          :feature_name,
          :scenario_name,
          :docstring,
          :datatable,
          # Standard ExUnit context keys to ignore
          :async,
          :case,
          :describe,
          :describe_line,
          :file,
          :line,
          :module,
          :registered,
          :test,
          :test_type,
          :test_pid
        ]

    assert custom_keys == []
    context
  end
end
