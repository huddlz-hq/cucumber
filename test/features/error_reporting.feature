Feature: Error Reporting

Background:
  Given initial setup is complete

Scenario: Missing step definition
  When I try to use a step with no definition
  Then I should see a helpful error message

Scenario: Step execution failure
  When I execute a step that fails
  Then I should see the error reason and step history