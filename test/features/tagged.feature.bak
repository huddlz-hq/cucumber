@feature-tag
Feature: Tags demonstration

@smoke
Scenario: Smoke test scenario
  Given a simple smoke test
  When I run with smoke tag filter
  Then this scenario should run

@regression
Scenario: Regression test scenario
  Given a regression test
  When I run with regression tag filter
  Then this scenario should run

@smoke @regression
Scenario: Multi-tagged scenario
  Given a test with multiple tags
  When I run with either smoke or regression tag filter
  Then this scenario should run

Scenario: Untagged scenario
  Given an untagged test
  When I run with tag filters
  Then this scenario should not run