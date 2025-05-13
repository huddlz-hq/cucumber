Feature: Parameter extraction

Scenario: Testing different parameter types
  Given a number 42
  And a decimal 3.14
  When I click "Submit" on the form
  Then I should see "Success" message on the dashboard