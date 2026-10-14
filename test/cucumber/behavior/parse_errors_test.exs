defmodule Cucumber.ParseErrorsBehaviorTest do
  @moduledoc """
  Behavior tests for what a user sees when a `.feature` file cannot be
  parsed: the error names the line and the column where its content
  starts, says what the parser expected there, and quotes that line.
  """

  use Cucumber.BehaviorCase

  test "a line the parser cannot read is reported where it is, with what was expected" do
    error =
      assert_raise Gherkin.ParseError, fn ->
        run_feature("""
        Feature: Broken

        Scenario: s
          Given a step
          Invalid line here
          Given another step
        """)
      end

    assert Exception.message(error) == """
           Gherkin parse error at line 5, column 3:
             Expected a step, table row, doc string, tag, comment or keyword line
           Near: "Invalid line here..."
           """
  end
end
