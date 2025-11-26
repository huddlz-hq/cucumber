defmodule Cucumber.ExpressionTest do
  use ExUnit.Case

  alias Cucumber.Expression

  describe "compile/1 with {atom} parameter" do
    test "compiles pattern with atom parameter" do
      {regex, converters} = Expression.compile("I have status {atom}")

      assert Regex.match?(regex, "I have status pending")
      assert length(converters) == 1
    end
  end

  describe "match/2 with {atom} parameter" do
    test "matches and converts atom parameter" do
      compiled = Expression.compile("I have status {atom}")

      assert {:match, [:pending]} = Expression.match("I have status pending", compiled)
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
      compiled = Expression.compile("I have status {atom}")

      assert :no_match = Expression.match("I have something else", compiled)
    end
  end
end
