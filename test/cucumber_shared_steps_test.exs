defmodule CucumberSharedStepsTest do
  use ExUnit.Case, async: true

  describe "Phase 2: Step Accumulation & Export" do
    test "shared module accumulates steps and provides __using__ macro" do
      defmodule TestSharedAccumulation do
        use Cucumber.SharedSteps
        
        defstep "first accumulated step" do
          %{step: :first}
        end
        
        defstep "second accumulated step with {string}", context do
          param = List.first(context.args)
          {:ok, %{step: :second, param: param}}
        end
      end
      
      # The module should now provide a __using__ macro
      assert macro_exported?(TestSharedAccumulation, :__using__, 1)
      
      # Check that it has the shared step definitions
      assert function_exported?(TestSharedAccumulation, :__cucumber_shared_patterns__, 0)
      patterns = TestSharedAccumulation.__cucumber_shared_patterns__()
      assert length(patterns) == 2
    end
    
    test "using a shared module imports all its steps" do
      # First define a shared module
      defmodule TestSharedExport do
        use Cucumber.SharedSteps
        
        defstep "exported step one" do
          %{exported: :one}
        end
        
        defstep "exported step {int}", context do
          num = List.first(context.args)
          %{exported: :two, number: num}
        end
      end
      
      # Now use it in another module that also uses Cucumber patterns
      defmodule TestUsingShared do
        # Need to set up the Cucumber infrastructure
        import Cucumber, only: [defstep: 2, defstep: 3]
        Module.register_attribute(__MODULE__, :cucumber_patterns, accumulate: true)
        @before_compile Cucumber
        
        use TestSharedExport
        
        # This module should now have the step functions
      end
      
      # Verify the steps were imported
      assert function_exported?(TestUsingShared, :step, 2)
      
      # Verify we have the patterns
      patterns = TestUsingShared.__cucumber_patterns__()
      assert length(patterns) == 2
      assert {"exported step one", _} = List.keyfind(patterns, "exported step one", 0)
      assert {"exported step {int}", _} = List.keyfind(patterns, "exported step {int}", 0)
    end
  end
  
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