defmodule Cucumber.DataTablesBehaviorTest do
  @moduledoc """
  Behavior tests for table cells reaching steps: empty cells keep their
  column in `context.datatable` and substitute `""` from Examples, escapes
  (`\\|`, `\\\\`, `\\n`) arrive unescaped, text after a row's last `|` is not
  a cell — in both `.feature` and `.feature.md` sources — and a row with the
  wrong number of cells fails the run instead of silently losing values.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule Steps do
    use Cucumber.StepDefinition

    step "these products:", context do
      Collector.record({:maps, context.datatable.maps})
      :ok
    end

    step "these notes:", context do
      Collector.record({:raw, context.datatable.raw})
      :ok
    end

    step "the flavor is {string}", %{args: [flavor]} do
      Collector.record({:flavor, flavor})
      :ok
    end
  end

  describe "empty cells" do
    @expected_events [
      {:maps,
       [
         %{"name" => "Doritos", "flavor" => "", "size" => "9 oz"},
         %{"name" => "Lay's", "flavor" => "Plain", "size" => ""}
       ]},
      {:flavor, ""}
    ]

    test "reach the step in their column and substitute as empty strings" do
      result =
        run_feature(
          """
          Feature: Sparse products

          Scenario Outline: optional columns
            Given these products:
              | name    | flavor | size |
              | Doritos |        | 9 oz |
              | Lay's   | Plain  |      |
            Then the flavor is "<flavor>"

            Examples:
              | flavor |
              |        |
          """,
          steps: [Steps]
        )

      assert result.failures == 0
      assert result.events == @expected_events
    end

    test "behave the same in a .feature.md source" do
      result =
        run_feature(
          """
          # Feature: Sparse products

          ## Scenario Outline: optional columns

          * Given these products:
            | name    | flavor | size |
            | ------- | ------ | ---- |
            | Doritos |        | 9 oz |
            | Lay's   | Plain  |      |
          * Then the flavor is "<flavor>"

          ### Examples:

            | flavor |
            | ------ |
            |        |
          """,
          steps: [Steps],
          file: unique_markdown_path()
        )

      assert result.failures == 0
      assert result.events == @expected_events
    end
  end

  describe "escaped cells" do
    @expected_events [
      {:maps,
       [
         %{"name" => "Salt | Vinegar", "flavor" => "back\\slash", "size" => "two\nlines"}
       ]},
      {:flavor, "a | b"}
    ]

    test "reach the step unescaped, in data tables and Examples substitution" do
      result =
        run_feature(
          ~S"""
          Feature: Escaped products

          Scenario Outline: escapes
            Given these products:
              | name            | flavor       | size       |
              | Salt \| Vinegar | back\\slash  | two\nlines |
            Then the flavor is "<flavor>"

            Examples:
              | flavor  |
              | a \| b  |
          """,
          steps: [Steps]
        )

      assert result.failures == 0
      assert result.events == @expected_events
    end

    test "behave the same in a .feature.md source" do
      result =
        run_feature(
          ~S"""
          # Feature: Escaped products

          ## Scenario Outline: escapes

          * Given these products:
            | name            | flavor       | size       |
            | --------------- | ------------ | ---------- |
            | Salt \| Vinegar | back\\slash  | two\nlines |
          * Then the flavor is "<flavor>"

          ### Examples:

            | flavor  |
            | ------- |
            | a \| b  |
          """,
          steps: [Steps],
          file: unique_markdown_path()
        )

      assert result.failures == 0
      assert result.events == @expected_events
    end
  end

  describe "unterminated rows" do
    test "text after the last pipe is not a cell" do
      result =
        run_feature(
          """
          Feature: Unterminated

          Scenario: stray text
            Given these notes:
              | note | stray
          """,
          steps: [Steps]
        )

      assert result.failures == 0
      assert result.events == [{:raw, [["note"]]}]
    end

    test "behave the same in a .feature.md source" do
      result =
        run_feature(
          """
          # Feature: Unterminated

          ## Scenario: stray text

          * Given these notes:
            | note | stray
          """,
          steps: [Steps],
          file: unique_markdown_path()
        )

      assert result.failures == 0
      assert result.events == [{:raw, [["note"]]}]
    end
  end

  describe "a row with the wrong number of cells fails instead of losing values" do
    test "in a data table row with fewer cells than the header" do
      assert_raise Gherkin.ParseError, ~r/3 cells to match the first row, got 2/, fn ->
        run_feature(
          """
          Feature: Ragged products

          Scenario: missing a cell
            Given these products:
              | name    | flavor | size |
              | Doritos | 9 oz   |
          """,
          steps: [Steps]
        )
      end
    end

    test "in a data table row with more cells than the header" do
      assert_raise Gherkin.ParseError, ~r/2 cells to match the first row, got 3/, fn ->
        run_feature(
          """
          Feature: Ragged products

          Scenario: an extra cell
            Given these products:
              | name    | flavor |
              | Doritos | Nacho  | 9 oz |
          """,
          steps: [Steps]
        )
      end
    end

    test "in an Examples row" do
      assert_raise Gherkin.ParseError, ~r/2 cells to match the first row, got 1/, fn ->
        run_feature(
          """
          Feature: Ragged examples

          Scenario Outline: missing a value
            Then the flavor is "<flavor>"

            Examples:
              | name    | flavor |
              | Doritos |
          """,
          steps: [Steps]
        )
      end
    end

    test "in a .feature.md source" do
      assert_raise Gherkin.ParseError, ~r/3 cells to match the first row, got 2/, fn ->
        run_feature(
          """
          # Feature: Ragged products

          ## Scenario: missing a cell

          * Given these products:
            | name    | flavor | size |
            | ------- | ------ | ---- |
            | Doritos | 9 oz   |
          """,
          steps: [Steps],
          file: unique_markdown_path()
        )
      end
    end
  end
end
