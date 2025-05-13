defmodule CucumberTagsTest do
  use Cucumber,
    feature: "tagged.feature",
    # Only run scenarios tagged with @smoke
    tags: ["smoke"]

  # Define step implementations for our tagged scenarios
  defstep "a simple smoke test", context do
    Map.put(context, :smoke_test, true)
  end

  defstep "I run with smoke tag filter", context do
    context
  end

  defstep "this scenario should run", context do
    context
  end

  defstep "a test with multiple tags", context do
    Map.put(context, :multi_tagged, true)
  end

  defstep "I run with either smoke or regression tag filter", context do
    context
  end

  # We don't define steps for the regression-only or untagged scenarios
  # since they shouldn't run with our smoke tag filter
end
