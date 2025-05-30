Feature: Step return value handling

Background:
  Given initial context is empty

Scenario: Return a map directly
  When I return a map directly with value "direct"
  Then I should see value "direct" in the context

Scenario: Return an :ok atom
  When I return an :ok atom
  Then the initial context should be preserved

Scenario: Return {:ok, map} tuple
  When I return a tuple with value "tuple"
  Then I should see value "tuple" in the context

Scenario: Return keyword list
  When I return a keyword list with value "keyword"
  Then I should see value "keyword" in the context
