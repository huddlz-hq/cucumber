# Feature: Markdown feature files

Feature files can also be written in Markdown (`.feature.md`). Prose like
this paragraph is documentation — only headings with Gherkin keywords,
bullet-list steps, and indented tables are executable.

## Scenario: steps are Markdown bullets

* Given a Markdown feature file
* When it is discovered alongside plain feature files
* Then its scenarios run like any other

## Scenario Outline: tables are Markdown tables

* Given a basket with <count> markdown cucumbers

### Examples:

  | count |
  | ----- |
  | 1     |
  | 3     |
