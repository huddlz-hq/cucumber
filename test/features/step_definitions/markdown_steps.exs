defmodule MarkdownSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "a Markdown feature file", _context do
    :ok
  end

  step "it is discovered alongside plain feature files", _context do
    :ok
  end

  step "its scenarios run like any other", _context do
    :ok
  end

  step "a basket with {int} markdown cucumbers", %{args: [count]} do
    assert count in [1, 3]
    :ok
  end
end
