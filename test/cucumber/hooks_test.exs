defmodule Cucumber.HooksTest do
  use ExUnit.Case, async: true
  
  describe "feature-level vs scenario-level hooks" do
    test "feature-level hooks run in setup, scenario-level hooks run per test" do
      # Create a test feature with database tag at feature level
      feature = %{
        name: "Test Feature",
        tags: ["database"],
        file: "test.feature",
        scenarios: [
          %{
            name: "Scenario 1",
            tags: [],
            steps: []
          },
          %{
            name: "Scenario 2", 
            tags: ["special"],
            steps: []
          }
        ]
      }
      
      # Test that run_scenario_before_hooks excludes feature-level tags
      # Mock context
      context = %{feature_tags: ["database"]}
      
      # Define a test module with hook functions
      defmodule TestHookModule do
        def database_hook(context), do: {:ok, Map.put(context, :db_hook_ran, true)}
        def special_hook(context), do: {:ok, Map.put(context, :special_hook_ran, true)}
      end
      
      # The hooks for this test
      hooks = [
        {:before_scenario, "@database", {TestHookModule, :database_hook}},
        {:before_scenario, "@special", {TestHookModule, :special_hook}}
      ]
      
      # Run scenario hooks for scenario 1 (no tags)
      {:ok, result_context} = Cucumber.Hooks.run_scenario_before_hooks(
        hooks,
        context,
        [],  # scenario 1 tags
        ["database"]  # feature tags
      )
      
      # Database hook should NOT have run because it's a feature-level tag
      refute Map.has_key?(result_context, :db_hook_ran)
      
      # Run scenario hooks for scenario 2 (with @special tag)
      {:ok, result_context_2} = Cucumber.Hooks.run_scenario_before_hooks(
        hooks,
        context,
        ["special"],  # scenario 2 tags  
        ["database"]  # feature tags
      )
      
      # Only special hook should have run
      assert result_context_2[:special_hook_ran] == true
      refute Map.has_key?(result_context_2, :db_hook_ran)
    end
    
    test "global hooks run per-scenario, not in feature setup" do
      # Define a test module with a global hook function
      defmodule GlobalHookModule do
        def global_hook(context) do
          count = Map.get(context, :global_hook_count, 0)
          {:ok, Map.put(context, :global_hook_count, count + 1)}
        end
      end

      hooks = [
        {:before_scenario, nil, {GlobalHookModule, :global_hook}},
        {:before_scenario, "@database", {GlobalHookModule, :global_hook}}
      ]

      context = %{}

      # filter_hooks (used in setup) should NOT include global hooks
      setup_hooks = Cucumber.Hooks.filter_hooks(hooks, :before_scenario, ["database"])

      # Only the @database hook should be returned, not the global hook
      assert length(setup_hooks) == 1

      # run_before_hooks (setup) should not run global hooks
      {:ok, setup_context} = Cucumber.Hooks.run_before_hooks(hooks, context, ["database"])
      assert Map.get(setup_context, :global_hook_count, 0) == 1

      # run_scenario_before_hooks should run global hooks
      {:ok, scenario_context} =
        Cucumber.Hooks.run_scenario_before_hooks(hooks, context, [], ["database"])

      assert scenario_context.global_hook_count == 1
    end
  end
end