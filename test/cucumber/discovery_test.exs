defmodule Cucumber.DiscoveryTest do
  use ExUnit.Case

  alias Cucumber.Discovery

  describe "discover/1 with syntax errors" do
    test "propagates syntax errors during step discovery instead of silencing them" do
      temp_dir = Path.join(System.tmp_dir(), "discover_test_#{:rand.uniform(10000)}")
      step_dir = Path.join(temp_dir, "step_definitions")
      File.mkdir_p!(step_dir)

      # Create a step file with syntax error
      invalid_file = Path.join(step_dir, "syntax_error.exs")

      File.write!(invalid_file, """
      defmodule SyntaxErrorSteps do
        use Cucumber.StepDefinition

        # Missing 'do' - syntax error
        step "I have syntax error", context
          context
        end
      end
      """)

      try do
        # Discovery should fail with syntax error, not return nil
        # This verifies the fix for not silencing import errors
        assert_raise SyntaxError, fn ->
          Discovery.discover(steps: [Path.join(step_dir, "*.exs")])
        end
      after
        File.rm_rf(temp_dir)
      end
    end

    test "successfully discovers valid step definitions" do
      temp_dir = Path.join(System.tmp_dir(), "discover_valid_test_#{:rand.uniform(10000)}")
      step_dir = Path.join(temp_dir, "step_definitions")
      File.mkdir_p!(step_dir)

      # Create a valid step file
      valid_file = Path.join(step_dir, "valid_steps.exs")

      File.write!(valid_file, """
      defmodule ValidDiscoverySteps do
        use Cucumber.StepDefinition

        step "I am a valid step", context do
          context
        end
      end
      """)

      try do
        # Discovery should succeed
        result = Discovery.discover(steps: [Path.join(step_dir, "*.exs")])

        assert %Discovery.DiscoveryResult{} = result
        assert length(result.step_modules) == 1
        assert Map.has_key?(result.step_registry, "I am a valid step")
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 feature discovery" do
    test "discovers feature files from patterns" do
      temp_dir = Path.join(System.tmp_dir(), "feature_discover_#{:rand.uniform(10000)}")
      File.mkdir_p!(temp_dir)

      feature_file = Path.join(temp_dir, "example.feature")

      File.write!(feature_file, """
      Feature: Example feature
        Scenario: Example scenario
          Given a step
      """)

      try do
        result = Discovery.discover(features: [Path.join(temp_dir, "*.feature")], steps: [])

        assert length(result.features) == 1
        [feature] = result.features
        assert feature.name == "Example feature"
        assert feature.file == feature_file
      after
        File.rm_rf(temp_dir)
      end
    end

    test "discovers multiple feature files" do
      temp_dir = Path.join(System.tmp_dir(), "multi_feature_#{:rand.uniform(10000)}")
      File.mkdir_p!(temp_dir)

      File.write!(Path.join(temp_dir, "first.feature"), """
      Feature: First feature
        Scenario: First scenario
          Given a step
      """)

      File.write!(Path.join(temp_dir, "second.feature"), """
      Feature: Second feature
        Scenario: Second scenario
          Given another step
      """)

      try do
        result = Discovery.discover(features: [Path.join(temp_dir, "*.feature")], steps: [])

        assert length(result.features) == 2
        names = Enum.map(result.features, & &1.name) |> Enum.sort()
        assert names == ["First feature", "Second feature"]
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 step registry" do
    test "builds registry with module and metadata" do
      temp_dir = Path.join(System.tmp_dir(), "registry_test_#{:rand.uniform(10000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      File.write!(Path.join(step_dir, "my_steps.exs"), """
      defmodule RegistryTestSteps#{:rand.uniform(10000)} do
        use Cucumber.StepDefinition

        step "I have {int} items", context do
          context
        end
      end
      """)

      try do
        result = Discovery.discover(steps: [Path.join(step_dir, "*.exs")])

        assert Map.has_key?(result.step_registry, "I have {int} items")
        {module, metadata} = result.step_registry["I have {int} items"]
        assert is_atom(module)
        assert is_map(metadata)
        assert Map.has_key?(metadata, :line)
        assert Map.has_key?(metadata, :file)
      after
        File.rm_rf(temp_dir)
      end
    end

    test "combines steps from multiple modules" do
      temp_dir = Path.join(System.tmp_dir(), "multi_module_#{:rand.uniform(10000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      rand_suffix = :rand.uniform(10000)

      File.write!(Path.join(step_dir, "first_steps.exs"), """
      defmodule FirstModuleSteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "step from first module", context do
          context
        end
      end
      """)

      File.write!(Path.join(step_dir, "second_steps.exs"), """
      defmodule SecondModuleSteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "step from second module", context do
          context
        end
      end
      """)

      try do
        result = Discovery.discover(steps: [Path.join(step_dir, "*.exs")])

        assert length(result.step_modules) == 2
        assert Map.has_key?(result.step_registry, "step from first module")
        assert Map.has_key?(result.step_registry, "step from second module")
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 duplicate step detection" do
    test "raises on duplicate step definitions" do
      temp_dir = Path.join(System.tmp_dir(), "duplicate_test_#{:rand.uniform(10000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      rand_suffix = :rand.uniform(10000)

      File.write!(Path.join(step_dir, "a_steps.exs"), """
      defmodule DuplicateASteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "I am duplicated", context do
          context
        end
      end
      """)

      File.write!(Path.join(step_dir, "b_steps.exs"), """
      defmodule DuplicateBSteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "I am duplicated", context do
          context
        end
      end
      """)

      try do
        assert_raise RuntimeError, ~r/Duplicate step definition/, fn ->
          Discovery.discover(steps: [Path.join(step_dir, "*.exs")])
        end
      after
        File.rm_rf(temp_dir)
      end
    end

    test "duplicate error includes file and line information" do
      temp_dir = Path.join(System.tmp_dir(), "dup_info_test_#{:rand.uniform(10000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      rand_suffix = :rand.uniform(10000)

      File.write!(Path.join(step_dir, "first.exs"), """
      defmodule DupInfoFirst#{rand_suffix} do
        use Cucumber.StepDefinition

        step "duplicate pattern", context do
          context
        end
      end
      """)

      File.write!(Path.join(step_dir, "second.exs"), """
      defmodule DupInfoSecond#{rand_suffix} do
        use Cucumber.StepDefinition

        step "duplicate pattern", context do
          context
        end
      end
      """)

      try do
        error =
          assert_raise RuntimeError, fn ->
            Discovery.discover(steps: [Path.join(step_dir, "*.exs")])
          end

        assert error.message =~ "First defined in:"
        assert error.message =~ "Also defined in:"
        assert error.message =~ "duplicate pattern"
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 with empty patterns" do
    test "returns empty results for non-matching patterns" do
      result =
        Discovery.discover(
          features: ["nonexistent/**/*.feature"],
          steps: ["nonexistent/**/*.exs"],
          support: ["nonexistent/**/*.exs"]
        )

      assert result.features == []
      assert result.step_modules == []
      assert result.step_registry == %{}
      assert result.hook_modules == []
    end
  end
end
