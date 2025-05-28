defmodule CucumberDiscoveryPocTest do
  use ExUnit.Case, async: true

  # First, let's just test the StepDefinition macro works
  describe "StepDefinition macro" do
    test "can define a module with steps" do
      # Define a test module inline
      defmodule TestSteps do
        use Cucumber.StepDefinition

        step "test step one", context do
          Map.put(context, :step_one, true)
        end

        step "test step {string}", %{args: [value]} = context do
          Map.put(context, :value, value)
        end
      end

      # Check the module has the right functions
      assert function_exported?(TestSteps, :__cucumber_steps__, 0)
      assert function_exported?(TestSteps, :step, 2)

      # Check steps are registered
      steps = TestSteps.__cucumber_steps__()
      assert length(steps) == 2

      # Check step execution
      result = TestSteps.step(%{}, "test step one")
      assert result.step_one == true

      result2 = TestSteps.step(%{args: ["hello"]}, "test step {string}")
      assert result2.value == "hello"
    end
  end

  # We'll test discovery separately once we know modules work
end
