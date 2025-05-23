defmodule SharedSteps.Shopping do
  @moduledoc """
  Shared shopping cart steps for use across multiple test modules.
  """
  use Cucumber.SharedSteps

  defstep "I have {int} items in my cart", %{args: [item_count]} = context do
    Map.put(context, :cart_items, item_count)
  end

  defstep "I should have {int} items total", %{args: [expected_count]} = context do
    assert context.cart_items == expected_count
    context
  end
end
