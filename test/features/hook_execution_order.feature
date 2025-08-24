@track_execution
Feature: Hook Execution Order
  To verify hooks run in the correct order

  Background:
    Given I record "background_step"

  Scenario: Verify execution order
    When I record "scenario_step"
    Then the execution order should be "feature_hook,background_step,scenario_step"