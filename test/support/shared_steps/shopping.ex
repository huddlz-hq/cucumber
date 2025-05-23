defmodule SharedSteps.Shopping do
  @moduledoc """
  Shared shopping cart steps for use across multiple test modules.
  """
  use Cucumber.SharedSteps

  defstep "I have {int} items in my cart", context do
    item_count = List.first(context.args)
    Map.put(context, :cart_items, item_count)
  end

  defstep "I should have {int} items total", context do
    expected_count = List.first(context.args)
    assert context.cart_items == expected_count
    context
  end
end
