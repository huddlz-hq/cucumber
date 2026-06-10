Feature: Regular expression step definitions
  Steps can be implemented with regexes as well as cucumber expressions.

  Scenario: regex captures arrive as strings
    Given a basket holding 3 apples and 2 pears
    Then the regex basket total is "5"

  Scenario: optional regex groups are nil when absent
    Given a basket holding 4 apples
    Then the regex basket total is "4"
