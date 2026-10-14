defmodule Cucumber.ParseErrorsBehaviorTest do
  @moduledoc """
  Behavior tests for what a user sees when a feature file cannot be
  parsed: the error names the file, the line and the column where its
  content starts, says what the parser expected there, and quotes that
  line.
  """

  use Cucumber.BehaviorCase

  test "a line the parser cannot read is reported by file, line and column, with what was expected" do
    error =
      assert_raise Gherkin.ParseError, fn ->
        run_feature(
          """
          Feature: Broken

          Scenario: s
            Given a step
            Invalid line here
            Given another step
          """,
          file: "test/fixtures/generated/broken.feature"
        )
      end

    assert Exception.message(error) == """
           Gherkin parse error at test/fixtures/generated/broken.feature:5:3:
             Expected a step, table row, doc string, tag, comment or keyword line
           Near: "Invalid line here..."
           """
  end

  test "a .feature.md parse error names the file the same way" do
    error =
      assert_raise Gherkin.ParseError, fn ->
        run_feature(
          """
          # Feature: Broken

          * Given a step before any scenario
          """,
          file: "test/fixtures/generated/broken.feature.md"
        )
      end

    assert Exception.message(error) =~
             "Gherkin parse error at test/fixtures/generated/broken.feature.md:3:1:"
  end
end
