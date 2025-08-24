@database
Feature: Feature Level Tag Support
  As a developer
  I want to use feature-level tags like @database
  So that hooks run before background steps

  Background:
    Given the database is initialized

  Scenario: First scenario uses database
    When I query the database
    Then I should get results

  @special
  Scenario: Second scenario with additional tag
    When I query the database with special permissions
    Then I should get special results