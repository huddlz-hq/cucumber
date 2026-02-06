defmodule Cucumber.ExpressionTest do
  use ExUnit.Case

  alias Cucumber.Expression

  describe "compile/1" do
    test "compiles simple literal pattern" do
      compiled = Expression.compile("I have items")

      assert is_list(compiled)
      assert [{:literal, "I have items"}] = compiled
    end

    test "compiles pattern with int parameter" do
      compiled = Expression.compile("I have {int} items")

      assert [{:literal, "I have "}, {:parameter, "int", _, :required}, {:literal, " items"}] =
               compiled
    end

    test "compiles pattern with string parameter" do
      compiled = Expression.compile("I click {string} button")

      assert [{:literal, "I click "}, {:parameter, "string", _, :required}, {:literal, " button"}] =
               compiled
    end

    test "compiles pattern with multiple parameters" do
      compiled = Expression.compile("I add {int} items to {word} list")

      assert [
               {:literal, "I add "},
               {:parameter, "int", _, :required},
               {:literal, " items to "},
               {:parameter, "word", _, :required},
               {:literal, " list"}
             ] = compiled
    end

    test "compiles pattern with optional parameter" do
      compiled = Expression.compile("I have {int?} items")

      assert [{:literal, "I have "}, {:parameter, "int", _, :optional}, {:literal, " items"}] =
               compiled
    end

    test "compiles pattern with optional text" do
      compiled = Expression.compile("I have cucumber(s)")

      assert [
               {:literal, "I have cucumber"},
               {:optional, "s"}
             ] = compiled
    end

    test "compiles pattern with alternation" do
      compiled = Expression.compile("I click/tap the button")

      assert [
               {:literal, "I "},
               {:alternation, ["click", "tap"]},
               {:literal, " the button"}
             ] = compiled
    end

    test "compiles pattern with escape sequences for braces" do
      compiled = Expression.compile("I see \\{literal\\} braces")

      assert [{:literal, "I see {literal} braces"}] = compiled
    end

    test "compiles pattern with escape sequences for parentheses" do
      compiled = Expression.compile("call\\(\\)")

      assert [{:literal, "call()"}] = compiled
    end

    test "compiles pattern with escape sequences for slash" do
      compiled = Expression.compile("path\\/to\\/file")

      assert [{:literal, "path/to/file"}] = compiled
    end

    test "compiles pattern with escape sequence for backslash" do
      compiled = Expression.compile("path\\\\file")

      assert [{:literal, "path\\file"}] = compiled
    end

    test "raises on unknown parameter type" do
      assert_raise RuntimeError, ~r/Unknown parameter type: unknown/, fn ->
        Expression.compile("I have {unknown} items")
      end
    end
  end

  describe "match/2 with {int} parameter" do
    test "matches and converts positive integer" do
      compiled = Expression.compile("I have {int} items")

      assert {:match, [42]} = Expression.match("I have 42 items", compiled)
    end

    test "matches and converts negative integer" do
      compiled = Expression.compile("temperature is {int} degrees")

      assert {:match, [-5]} = Expression.match("temperature is -5 degrees", compiled)
    end

    test "matches zero" do
      compiled = Expression.compile("I have {int} items")

      assert {:match, [0]} = Expression.match("I have 0 items", compiled)
    end

    test "returns no_match for non-integer" do
      compiled = Expression.compile("I have {int} items")

      assert :no_match = Expression.match("I have many items", compiled)
    end
  end

  describe "match/2 with {float} parameter" do
    test "matches and converts positive float" do
      compiled = Expression.compile("price is {float} dollars")

      assert {:match, [19.99]} = Expression.match("price is 19.99 dollars", compiled)
    end

    test "matches and converts negative float" do
      compiled = Expression.compile("change is {float} degrees")

      assert {:match, [-3.5]} = Expression.match("change is -3.5 degrees", compiled)
    end

    test "returns no_match for integer (no decimal)" do
      compiled = Expression.compile("price is {float} dollars")

      assert :no_match = Expression.match("price is 20 dollars", compiled)
    end
  end

  describe "match/2 with {string} parameter" do
    test "matches quoted string" do
      compiled = Expression.compile("I click {string} button")

      assert {:match, ["Submit"]} = Expression.match("I click \"Submit\" button", compiled)
    end

    test "matches empty string" do
      compiled = Expression.compile("I enter {string}")

      assert {:match, [""]} = Expression.match("I enter \"\"", compiled)
    end

    test "matches string with spaces" do
      compiled = Expression.compile("I see {string}")

      assert {:match, ["hello world"]} = Expression.match("I see \"hello world\"", compiled)
    end

    test "handles escaped quotes in string" do
      compiled = Expression.compile("I see {string}")

      assert {:match, ["say \"hello\""]} =
               Expression.match("I see \"say \\\"hello\\\"\"", compiled)
    end

    test "returns no_match without quotes" do
      compiled = Expression.compile("I click {string} button")

      assert :no_match = Expression.match("I click Submit button", compiled)
    end
  end

  describe "match/2 with {word} parameter" do
    test "matches single word" do
      compiled = Expression.compile("I go to {word} page")

      assert {:match, ["home"]} = Expression.match("I go to home page", compiled)
    end

    test "stops at whitespace" do
      compiled = Expression.compile("I see {word}")

      assert {:match, ["hello"]} = Expression.match("I see hello", compiled)
    end
  end

  describe "match/2 with {atom} parameter" do
    test "matches and converts atom" do
      compiled = Expression.compile("status is {atom}")

      assert {:match, [:pending]} = Expression.match("status is pending", compiled)
    end

    test "matches atom with underscores" do
      compiled = Expression.compile("status is {atom}")

      assert {:match, [:in_progress]} = Expression.match("status is in_progress", compiled)
    end

    test "matches atom with numbers" do
      compiled = Expression.compile("use {atom} format")

      assert {:match, [:utf8]} = Expression.match("use utf8 format", compiled)
    end

    test "returns no_match when text doesn't match" do
      compiled = Expression.compile("status is {atom}")

      assert :no_match = Expression.match("something else", compiled)
    end
  end

  describe "match/2 with multiple parameters" do
    test "matches multiple parameters of same type" do
      compiled = Expression.compile("from {int} to {int}")

      assert {:match, [1, 10]} = Expression.match("from 1 to 10", compiled)
    end

    test "matches multiple parameters of different types" do
      compiled = Expression.compile("I add {int} items to {word} list")

      assert {:match, [5, "shopping"]} =
               Expression.match("I add 5 items to shopping list", compiled)
    end
  end

  describe "match/2 with optional parameters" do
    test "matches when optional parameter is present" do
      compiled = Expression.compile("I have {int?} items")

      assert {:match, [5]} = Expression.match("I have 5 items", compiled)
    end

    test "returns nil when optional parameter is absent" do
      compiled = Expression.compile("I have {int?}items")

      assert {:match, [nil]} = Expression.match("I have items", compiled)
    end

    test "handles optional with surrounding text" do
      compiled = Expression.compile("count: {int?}")

      assert {:match, [42]} = Expression.match("count: 42", compiled)
      assert {:match, [nil]} = Expression.match("count: ", compiled)
    end
  end

  describe "match/2 with optional text" do
    test "matches with optional text present" do
      compiled = Expression.compile("I have cucumber(s)")

      assert {:match, []} = Expression.match("I have cucumbers", compiled)
    end

    test "matches with optional text absent" do
      compiled = Expression.compile("I have cucumber(s)")

      assert {:match, []} = Expression.match("I have cucumber", compiled)
    end

    test "optional text with parameter" do
      compiled = Expression.compile("I have {int} cucumber(s)")

      assert {:match, [1]} = Expression.match("I have 1 cucumber", compiled)
      assert {:match, [5]} = Expression.match("I have 5 cucumbers", compiled)
    end

    test "optional text is not captured" do
      compiled = Expression.compile("the following group(s) exist:")

      assert {:match, []} = Expression.match("the following group exist:", compiled)
      assert {:match, []} = Expression.match("the following groups exist:", compiled)
    end

    test "optional text with multiple characters" do
      compiled = Expression.compile("I (do not )have items")

      assert {:match, []} = Expression.match("I have items", compiled)
      assert {:match, []} = Expression.match("I do not have items", compiled)
    end
  end

  describe "match/2 with alternation" do
    test "matches first option" do
      compiled = Expression.compile("I click/tap the button")

      assert {:match, []} = Expression.match("I click the button", compiled)
    end

    test "matches second option" do
      compiled = Expression.compile("I click/tap the button")

      assert {:match, []} = Expression.match("I tap the button", compiled)
    end

    test "matches with multiple options" do
      compiled = Expression.compile("I click/tap/press it")

      assert {:match, []} = Expression.match("I press it", compiled)
    end

    test "returns no_match for non-matching option" do
      compiled = Expression.compile("I click/tap the button")

      assert :no_match = Expression.match("I push the button", compiled)
    end

    test "alternation is not captured" do
      compiled = Expression.compile("I have/own {int} items")

      assert {:match, [5]} = Expression.match("I have 5 items", compiled)
      assert {:match, [3]} = Expression.match("I own 3 items", compiled)
    end
  end

  describe "match/2 with escape sequences" do
    test "matches literal braces" do
      compiled = Expression.compile("I see \\{braces\\}")

      assert {:match, []} = Expression.match("I see {braces}", compiled)
    end

    test "combines escaped and parameters" do
      compiled = Expression.compile("\\{count\\}: {int}")

      assert {:match, [42]} = Expression.match("{count}: 42", compiled)
    end

    test "matches literal parentheses" do
      compiled = Expression.compile("call\\(\\)")

      assert {:match, []} = Expression.match("call()", compiled)
    end

    test "matches literal forward slash" do
      compiled = Expression.compile("path\\/to\\/file")

      assert {:match, []} = Expression.match("path/to/file", compiled)
    end

    test "matches literal backslash" do
      compiled = Expression.compile("path\\\\file")

      assert {:match, []} = Expression.match("path\\file", compiled)
    end
  end

  describe "match/2 edge cases" do
    test "matches empty pattern" do
      compiled = Expression.compile("")

      assert {:match, []} = Expression.match("", compiled)
    end

    test "returns no_match for partial match" do
      compiled = Expression.compile("hello")

      assert :no_match = Expression.match("hello world", compiled)
    end

    test "returns no_match for extra text at start" do
      compiled = Expression.compile("world")

      assert :no_match = Expression.match("hello world", compiled)
    end

    test "handles special regex characters in literals" do
      compiled = Expression.compile("price is $100.00")

      assert {:match, []} = Expression.match("price is $100.00", compiled)
    end

    test "compile returns same result on repeated calls (idempotency)" do
      compiled1 = Expression.compile("I have {int} items")
      compiled2 = Expression.compile("I have {int} items")

      assert compiled1 == compiled2
    end
  end

  describe "match/2 with Unicode and special strings" do
    test "matches string parameter containing Unicode" do
      compiled = Expression.compile("I see {string}")

      assert {:match, ["héllo wörld"]} = Expression.match("I see \"héllo wörld\"", compiled)
    end

    test "matches string parameter containing emoji" do
      compiled = Expression.compile("I see {string}")

      assert {:match, ["hello 🎉🥒"]} = Expression.match("I see \"hello 🎉🥒\"", compiled)
    end

    test "matches very long string parameter" do
      long_text = String.duplicate("a", 500)
      compiled = Expression.compile("I see {string}")

      assert {:match, [^long_text]} = Expression.match("I see \"#{long_text}\"", compiled)
    end

    test "matches literal text with Unicode characters" do
      compiled = Expression.compile("I see café")

      assert {:match, []} = Expression.match("I see café", compiled)
    end
  end
end
