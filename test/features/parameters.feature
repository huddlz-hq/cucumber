Feature: Parameter extraction

Scenario: Testing different parameter types
  Given a number 42
  And a decimal 3.14
  When I click "Submit" on the form
  Then I should see "Success" message on the dashboard

Scenario: Atom parameter extraction
  Given status is pending
  Then the status should be the atom pending

Scenario: Optional text for pluralization
  Given I have 1 cucumber
  And I have 5 cucumbers
  Then the total cucumber count should be 6

Scenario: Alternation matching
  Given I am on the home page
  When I click the submit button
  Then I should have interacted