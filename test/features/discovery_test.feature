Feature: Discovery Test
  Testing the new discovery engine

  Scenario: Basic discovery
    Given I have a step definition
    When I run discovery
    Then the step should be found