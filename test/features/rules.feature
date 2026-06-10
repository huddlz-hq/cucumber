Feature: Rules group related scenarios
  Rules express a business rule with its own examples.

  Background:
    Given a ledger entry for "feature setup"

  Rule: Totals accumulate ledger entries
    Rule backgrounds run after the feature background.

    Background:
      Given a ledger entry for "rule setup"

    Example: both backgrounds apply
      When I total the ledger
      Then the ledger total is 2

  Rule: Rules can use the Scenario keyword too
    Scenario: only the feature background applies
      When I total the ledger
      Then the ledger total is 1
