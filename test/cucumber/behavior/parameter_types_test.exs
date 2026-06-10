defmodule Cucumber.ParameterTypesBehaviorTest do
  @moduledoc """
  Behavior tests for custom parameter types (#23), driven by the CCK
  `parameter-types` and `unknown-parameter-type` samples plus the issue
  checklist.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.BehaviorCase.Collector

  defmodule Types do
    use Cucumber.ParameterTypes

    parameter_type(:flight,
      regexp: ~r/([A-Z]{3})-([A-Z]{3})/,
      transform: fn from, to -> %{from: from, to: to} end
    )

    parameter_type(:color, regexp: ~r/red|blue|green/)

    parameter_type(:shouty,
      regexp: ~r/[A-Z]+/,
      transform: fn word -> String.downcase(word) end
    )

    parameter_type(:explosive,
      regexp: ~r/TNT/,
      transform: fn _ -> raise "transformer exploded" end
    )
  end

  defmodule FlightSteps do
    use Cucumber.StepDefinition
    import ExUnit.Assertions

    step "{flight} has been delayed", %{args: [flight]} do
      assert flight.from == "LHR"
      assert flight.to == "CDG"
      Collector.record({:flight, flight})
      :ok
    end
  end

  defmodule MixedTypeSteps do
    use Cucumber.StepDefinition

    step "I paint {int} walls {color} with {shouty} energy", %{args: args} do
      Collector.record({:painted, args})
      :ok
    end

    # Optional parameters follow the existing {int?} semantics: the value
    # must be glued to the following literal for the absent case to match.
    step "I might see a {color?}colored wall", %{args: [color]} do
      Collector.record({:maybe_color, color})
      :ok
    end

    step "handling {explosive} carefully", _context do
      Collector.record(:never_reached)
      :ok
    end
  end

  defmodule UnknownTypeSteps do
    use Cucumber.StepDefinition

    step "{airport} is closed because of a strike", _context do
      raise "Should not be called because airport parameter type has not been defined"
    end
  end

  describe "CCK: parameter-types" do
    test "a custom type transforms capture groups into a domain value" do
      run =
        run_feature(
          File.read!("test/fixtures/cck/parameter-types/parameter-types.feature"),
          steps: [FlightSteps],
          parameter_types: [Types]
        )

      assert %{total: 1, passed: 1, failures: 0} = run
      assert run.events == [{:flight, %{from: "LHR", to: "CDG"}}]
    end
  end

  describe "CCK: unknown-parameter-type" do
    test "a step using an unregistered type is undefined, with a suggestion" do
      {run, warning_output} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          run_feature(
            File.read!("test/fixtures/cck/unknown-parameter-type/unknown-parameter-type.feature"),
            steps: [UnknownTypeSteps]
          )
        end)

      # The definition is excluded with a warning; the step is undefined and
      # the scenario fails with the usual suggestion (CCK: "the suite will
      # run" — no hard crash).
      assert %{total: 1, passed: 0, failures: 1} = run
      assert run.output =~ "No matching step definition found"
      assert run.output =~ ~s(step "CDG is closed because of a strike")
      assert warning_output =~ "undefined parameter type {airport}"
    end
  end

  describe "custom parameter type semantics" do
    test "custom types combine with built-ins; no-transform types yield strings" do
      run =
        run_feature(
          """
          Feature: mixed types
            Scenario: all kinds at once
              Given I paint 3 walls blue with GUSTO energy
          """,
          steps: [MixedTypeSteps],
          parameter_types: [Types]
        )

      assert %{total: 1, passed: 1} = run
      # {int} converts, {color} has no transform (string), {shouty} downcases
      assert run.events == [{:painted, [3, "blue", "gusto"]}]
    end

    test "optional custom parameters yield nil when absent" do
      present =
        run_feature(
          """
          Feature: optional custom
            Scenario: present
              Given I might see a redcolored wall
          """,
          steps: [MixedTypeSteps],
          parameter_types: [Types]
        )

      assert present.events == [{:maybe_color, "red"}]

      absent =
        run_feature(
          """
          Feature: optional custom
            Scenario: absent
              Given I might see a colored wall
          """,
          steps: [MixedTypeSteps],
          parameter_types: [Types]
        )

      assert %{total: 1, passed: 1} = absent
      assert absent.events == [{:maybe_color, nil}]
    end

    test "a raising transformer fails the scenario with the transformer's error" do
      run =
        run_feature(
          """
          Feature: exploding transform
            Scenario: boom
              Given handling TNT carefully
          """,
          steps: [MixedTypeSteps],
          parameter_types: [Types]
        )

      assert %{total: 1, passed: 0, failures: 1} = run
      assert run.output =~ "transformer exploded"
      refute :never_reached in run.events
    end
  end
end
