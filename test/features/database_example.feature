Feature: Database Example
  Demonstrates selective database setup using hooks

Scenario: Without database tag
  Given a step that checks database setup
  Then database should not be setup

@database
Scenario: With database tag
  Given a step that checks database setup
  Then database should be setup