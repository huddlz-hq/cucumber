@counted-steps
Feature: Run-level hooks

Scenario: before_all context is available to scenarios
  Given the run-level setup has happened
  Then the global hooks step counter has counted this scenario's steps
