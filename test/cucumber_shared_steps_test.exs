defmodule CucumberSharedStepsTest do
  use ExUnit.Case, async: true

  describe "Phase 1: Basic SharedSteps module" do
    test "can define a module using Cucumber.SharedSteps" do
      # This test verifies that a module can use Cucumber.SharedSteps and compile successfully
      defmodule TestSharedBasic do
        use Cucumber.SharedSteps
        
        defstep "a basic shared step" do
          :ok
        end
        
        defstep "a shared step with parameter {string}", context do
          param = List.first(context.args)
          {:ok, %{param: param}}
        end
      end
      
      # Verify the module compiled
      assert TestSharedBasic.__info__(:module) == TestSharedBasic
      
      # In phase 1, we're just verifying:
      # 1. The module can use Cucumber.SharedSteps
      # 2. It can define steps using defstep
      # 3. The imports work correctly
      
      # The actual step function should be defined
      assert function_exported?(TestSharedBasic, :step, 2)
    end
    
    test "shared module can define steps with both arities" do
      defmodule TestSharedArities do
        use Cucumber.SharedSteps
        
        # Step without context parameter
        defstep "step without context" do
          %{result: :no_context}
        end
        
        # Step with context parameter
        defstep "step with context", context do
          Map.put(context, :result, :with_context)
        end
      end
      
      # Just verify it compiles - we'll test actual usage in phase 3
      assert TestSharedArities.__info__(:module) == TestSharedArities
    end
    
    test "shared module has access to imported defstep macro" do
      # This test ensures the import is working correctly
      defmodule TestSharedImport do
        use Cucumber.SharedSteps
        
        # This should compile because defstep is imported
        defstep "imported step works", _context do
          :ok
        end
      end
      
      assert TestSharedImport.__info__(:module) == TestSharedImport
    end
  end
end