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

  describe "Phase 5: Multiple Shared Modules" do
    test "can use multiple shared modules together" do
      # Define first shared module
      defmodule SharedA do
        use Cucumber.SharedSteps

        defstep "step from module A" do
          %{module_a: true}
        end

        defstep "shared step {int}", context do
          num = List.first(context.args)
          Map.put(context, :number_from_a, num)
        end
      end

      # Define second shared module
      defmodule SharedB do
        use Cucumber.SharedSteps

        defstep "step from module B" do
          %{module_b: true}
        end

        defstep "another shared step {string}", context do
          str = List.first(context.args)
          Map.put(context, :string_from_b, str)
        end
      end

      # Define third shared module
      defmodule SharedC do
        use Cucumber.SharedSteps

        defstep "step from module C" do
          %{module_c: true}
        end
      end

      # Use all three modules
      defmodule TestMultipleShared do
        Module.register_attribute(__MODULE__, :cucumber_patterns, accumulate: true)
        @before_compile Cucumber
        import Cucumber, only: [defstep: 2, defstep: 3]

        use SharedA
        use SharedB
        use SharedC

        # Local step
        defstep "local step in test module" do
          %{local: true}
        end
      end

      # Verify all steps are available
      patterns = TestMultipleShared.__cucumber_patterns__()
      pattern_texts = Enum.map(patterns, fn {text, _} -> text end)

      assert "step from module A" in pattern_texts
      assert "step from module B" in pattern_texts
      assert "step from module C" in pattern_texts
      assert "shared step {int}" in pattern_texts
      assert "another shared step {string}" in pattern_texts
      assert "local step in test module" in pattern_texts

      # Total should be 6 (3 + 2 + 1)
      assert length(patterns) == 6
    end
  end

  describe "Phase 6: Edge Cases and Conflicts" do
    test "first definition wins when same pattern in multiple modules" do
      defmodule ConflictA do
        use Cucumber.SharedSteps

        defstep "conflicting step", _context do
          %{winner: :module_a}
        end
      end

      defmodule ConflictB do
        use Cucumber.SharedSteps

        defstep "conflicting step", _context do
          %{winner: :module_b}
        end
      end

      defmodule TestConflict do
        Module.register_attribute(__MODULE__, :cucumber_patterns, accumulate: true)
        @before_compile Cucumber

        # Module A should win (first one imported)
        use ConflictA
        use ConflictB
      end

      # Execute the step to see which one wins
      result = TestConflict.step(%{}, "conflicting step")
      assert result.winner == :module_a
    end

    test "shared steps come before local steps (first definition wins)" do
      defmodule SharedWithOverride do
        use Cucumber.SharedSteps

        defstep "overridable step", _context do
          %{source: :shared}
        end
      end

      defmodule TestOverride do
        Module.register_attribute(__MODULE__, :cucumber_patterns, accumulate: true)
        @before_compile Cucumber
        import Cucumber, only: [defstep: 2, defstep: 3]

        use SharedWithOverride

        # This won't override - shared step comes first
        defstep "overridable step", _context do
          %{source: :local}
        end
      end

      # Shared definition wins (first match)
      result = TestOverride.step(%{}, "overridable step")
      assert result.source == :shared
    end

    test "shared modules can use other shared modules" do
      defmodule BaseShared do
        use Cucumber.SharedSteps

        defstep "base step", _context do
          %{base: true}
        end
      end

      defmodule ComposedShared do
        use Cucumber.SharedSteps
        use BaseShared

        defstep "composed step", _context do
          %{composed: true}
        end
      end

      defmodule TestComposed do
        Module.register_attribute(__MODULE__, :cucumber_patterns, accumulate: true)
        @before_compile Cucumber

        use ComposedShared
      end

      # Should have both base and composed steps
      patterns = TestComposed.__cucumber_patterns__()
      pattern_texts = Enum.map(patterns, fn {text, _} -> text end)

      assert "base step" in pattern_texts
      assert "composed step" in pattern_texts
    end
  end

  describe "Phase 4: Error Reporting and Line Numbers" do
    test "error messages preserve line numbers from shared steps" do
      defmodule SharedWithError do
        use Cucumber.SharedSteps
        
        defstep "step that will be tested", context do
          # We'll capture the line number here
          line = __ENV__.line
          # Return it so we can verify
          Map.put(context, :step_line, line)
        end
      end
      
      defmodule TestErrorReporting do
        Module.register_attribute(__MODULE__, :cucumber_patterns, accumulate: true)
        @before_compile Cucumber
        
        use SharedWithError
      end
      
      # Execute the step and verify line number is preserved
      result = TestErrorReporting.step(%{}, "step that will be tested")
      
      # The line number should be from the shared module definition
      assert result.step_line > 230  # Should be after the module definition
      assert result.step_line < 250  # Should be before the end of the test
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
