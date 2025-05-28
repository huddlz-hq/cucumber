Feature: Shared Steps Integration
  This feature tests that shared steps work correctly with Cucumber
  
  Scenario: Using shared authentication steps
    Given I am logged in as "test@example.com"
    When I navigate to my profile
    Then I should be authenticated
    
  Scenario: Shared steps with different parameters
    Given I am logged in as "admin@example.com"
    And I have 5 items in my cart
    When I view my account details
    Then I should see "admin@example.com" as the current user
    And I should have 5 items total