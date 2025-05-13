defmodule CucumberMacroTest do
  use Cucumber, feature: "simple.feature"

  defstep "a simple step", context do
    Map.put(context, :simple, true)
  end
end
