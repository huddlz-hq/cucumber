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
end