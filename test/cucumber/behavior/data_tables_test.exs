defmodule Cucumber.DataTablesBehaviorTest do
  @moduledoc """
  Behavior tests for table cells reaching steps: empty cells keep their
  column in `context.datatable` and substitute `""` from Examples, in both
  `.feature` and `.feature.md` sources, and a row with the wrong number of
  cells fails the run instead of silently losing values.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule Steps do
    use Cucumber.StepDefinition

    step "these products:", context do
      Collector.record({:maps, context.datatable.maps})
      :ok
    end

    step "the flavor is {string}", %{args: [flavor]} do
      Collector.record({:flavor, flavor})
      :ok
    end
  end

  @expected_events [
    {:maps,
     [
       %{"name" => "Doritos", "flavor" => "", "size" => "9 oz"},
       %{"name" => "Lay's", "flavor" => "Plain", "size" => ""}
     ]},
    {:flavor, ""}
  ]

  test "empty cells reach the step in their column and substitute as empty strings" do
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

  test "a .feature.md source keeps empty cells the same way" do
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
        file: "test/fixtures/generated/sparse_#{System.unique_integer([:positive])}.feature.md"
      )

    assert result.failures == 0
    assert result.events == @expected_events
  end

  test "a row with fewer cells than the header fails to compile instead of dropping values" do
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
end
