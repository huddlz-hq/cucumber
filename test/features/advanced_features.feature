Feature: Advanced Gherkin features

Background:
  Given a setup with data table
    | key   | value |
    | setup | true  |

Scenario: Use docstring in a step
  Given a document with text
    """
    This is a multi-line
    docstring that preserves
    formatting and indentation.
    """
  When I process the document
  Then I should verify it contains "multi-line"

Scenario: Use data table in a step
  Given a table of users
    | username | email            | role  |
    | alice    | alice@email.com  | admin |
    | bob      | bob@email.com    | user  |
    | carol    | carol@email.com  | user  |
  When I search for "alice"
  Then I should find user with email "alice@email.com"