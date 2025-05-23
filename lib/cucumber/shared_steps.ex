defmodule Cucumber.SharedSteps do
  @moduledoc """
  Provides macros for defining reusable step definitions in separate modules.

  SharedSteps allows you to create modules containing step definitions that can be
  imported into multiple Cucumber test modules, promoting code reuse and organization.

  ## Usage

  Define a shared steps module:

      defmodule SharedSteps.Authentication do
        use Cucumber.SharedSteps
        
        defstep "I am logged in as {string}", context do
          username = List.first(context.args)
          {:ok, %{current_user: username, authenticated: true}}
        end
        
        defstep "I should be authenticated", context do
          assert context.authenticated == true
          context
        end
      end

  Use the shared steps in your test:

      defmodule UserProfileTest do
        use Cucumber, feature: "user_profile.feature"
        use SharedSteps.Authentication
        
        defstep "I navigate to my profile", context do
          {:ok, %{page: :profile}}
        end
      end

  This approach maintains proper file and line number information in error messages
  and stack traces, making debugging easier compared to runtime-loaded steps.

  ## Pattern Conflicts

  If multiple shared modules define the same step pattern, the first definition will
  be used and Elixir will generate a warning about unreachable clauses. This is
  intentional - each step pattern should have exactly one implementation to avoid
  ambiguity in your tests.
  """

  @doc """
  Sets up a module to define shared Cucumber steps.

  When `use Cucumber.SharedSteps` is called, it:
  - Imports the `defstep` macro from Cucumber
  - Marks the module as a shared steps module with `@cucumber_shared_module`

  ## Examples

      defmodule SharedSteps.Common do
        use Cucumber.SharedSteps
        
        defstep "I wait {int} seconds", context do
          seconds = List.first(context.args)
          Process.sleep(seconds * 1000)
          context
        end
      end
  """
  defmacro __using__(_opts) do
    quote do
      import Cucumber, only: [defstep: 2, defstep: 3]

      # Import ExUnit assertions for use in shared steps
      import ExUnit.Assertions

      # Register the same attribute that Cucumber uses for patterns
      Module.register_attribute(__MODULE__, :cucumber_patterns, accumulate: true)

      # Mark this as a shared module
      @cucumber_shared_module true

      @before_compile Cucumber.SharedSteps
      @before_compile Cucumber
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # Get all the patterns that were accumulated by defstep
    patterns = Module.get_attribute(env.module, :cucumber_patterns, [])

    # Reverse to maintain definition order
    patterns = Enum.reverse(patterns)

    quote do
      def __cucumber_shared_patterns__ do
        unquote(Macro.escape(patterns))
      end

      defmacro __using__(_opts) do
        module = __MODULE__
        patterns = __MODULE__.__cucumber_shared_patterns__()

        # Generate defstep calls that delegate to the shared module
        ast_list =
          for {pattern, _block} <- patterns do
            quote location: :keep do
              # Use the original defstep macro
              require Cucumber

              # Generate a step that delegates to the shared module
              Cucumber.defstep unquote(pattern), context do
                # Call the step function in the shared module
                unquote(module).step(context, unquote(pattern))
              end
            end
          end

        # Return a block that contains all the defstep calls
        quote do
          (unquote_splicing(ast_list))
        end
      end
    end
  end
end
