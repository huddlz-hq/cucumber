defmodule ReturnValuesSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  # Initialize context with a marker
  step "initial context is empty", context do
    Map.put(context, :initial, true)
  end

  # Test returning a map directly
  step "I return a map directly with value {string}", %{args: [value]} do
    %{direct_value: value}
  end

  # Test returning the :ok atom
  step "I return an :ok atom", _context do
    :ok
  end

  # Test returning {:ok, map} tuple
  step "I return a tuple with value {string}", %{args: [value]} do
    {:ok, %{tuple_value: value}}
  end

  # Test returning keyword list
  step "I return a keyword list with value {string}", %{args: [value]} do
    [keyword_value: value]
  end

  # Verify direct map return
  step "I should see value {string} in the context", %{args: [value]} = context do
    cond do
      # Check for direct map return value
      Map.has_key?(context, :direct_value) ->
        assert context.direct_value == value

      # Check for {:ok, map} tuple return value
      Map.has_key?(context, :tuple_value) ->
        assert context.tuple_value == value

      # Check for keyword list return value
      Map.has_key?(context, :keyword_value) ->
        assert context.keyword_value == value

      true ->
        flunk("Expected value #{value} not found in context")
    end

    context
  end

  # Verify context preservation with :ok or nil returns
  step "the initial context should be preserved", context do
    # Just verify our initial key is preserved
    assert context.initial == true
    context
  end
end
