Feature: Simple POC
  Proof of concept for new cucumber architecture

  Background:
    Given the system is initialized

  Scenario: Basic arithmetic
    Given I have the number 5
    When I add 3
    Then the result should be 8