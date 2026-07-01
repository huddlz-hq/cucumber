defmodule Cucumber.CompilerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Gherkin.{Feature, Scenario}

  describe "warn_on_empty_feature/1" do
    test "warns when the feature has zero scenarios" do
      feature = %Feature{name: "empty", scenarios: [], tags: []}
      feature = Map.put(feature, :file, "test/features/empty.feature")

      stderr = capture_io(:stderr, fn -> Cucumber.Compiler.warn_on_empty_feature(feature) end)

      assert stderr =~ "test/features/empty.feature"
      assert stderr =~ "zero scenarios"
    end

    test "is silent when the feature has at least one scenario" do
      feature = %Feature{
        name: "non-empty",
        scenarios: [%Scenario{name: "a", steps: [], tags: [], line: 1}],
        tags: []
      }

      feature = Map.put(feature, :file, "test/features/non_empty.feature")

      stderr = capture_io(:stderr, fn -> Cucumber.Compiler.warn_on_empty_feature(feature) end)

      assert stderr == ""
    end
  end
end
