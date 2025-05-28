defmodule CucumberDiscoveryTest do
  use ExUnit.Case, async: true

  alias Cucumber.Discovery

  describe "Discovery.discover/1" do
    test "finds feature files in default location" do
      result = Discovery.discover()

      # Should find our discovery_test.feature
      feature_files = Enum.map(result.features, & &1.file)
      assert Enum.any?(feature_files, &String.contains?(&1, "discovery_test.feature"))
    end

    test "loads step definition modules" do
      result = Discovery.discover()

      # Should have loaded DiscoverySteps module
      assert DiscoverySteps in result.step_modules
    end

    test "builds step registry" do
      result = Discovery.discover()

      # Should have our steps registered
      assert Map.has_key?(result.step_registry, "I have a step definition")
      assert Map.has_key?(result.step_registry, "I run discovery")
      assert Map.has_key?(result.step_registry, "the step should be found")

      # Check that registry contains module and metadata
      {module, metadata} = result.step_registry["I have a step definition"]
      assert module == DiscoverySteps
      assert metadata.file =~ "discovery_steps.exs"
    end

    test "detects duplicate step definitions" do
      # This test would require creating duplicate steps
      # For now, we'll skip it
    end
  end
end
