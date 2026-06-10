defmodule Cucumber.StepDefinition do
  @moduledoc """
  Provides macros for defining cucumber step definitions.

  ## Usage

      defmodule AuthenticationSteps do
        use Cucumber.StepDefinition

        step "I am logged in as {string}", %{args: [username]} = context do
          {:ok, Map.put(context, :current_user, username)}
        end
      end

  ## Regular expression patterns

  Steps can also be defined with a regular expression instead of a cucumber
  expression. The regex must match the entire step text, and capture groups
  arrive in `context.args` in order — always as strings (no type conversion),
  with `nil` for unmatched optional groups:

      step ~r/^I have (\\d+) cukes(?: in my (.+))?$/, %{args: [count, location]} = context do
        {:ok, Map.put(context, :cukes, {String.to_integer(count), location})}
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Cucumber.StepDefinition, only: [step: 2, step: 3]

      # Track step definitions
      Module.register_attribute(__MODULE__, :cucumber_steps, accumulate: true)
      Module.register_attribute(__MODULE__, :cucumber_step_count, [])

      @before_compile Cucumber.StepDefinition
    end
  end

  @doc """
  Defines a step implementation.

  The pattern is either a cucumber expression string or a regular expression
  (`~r//` sigil) — see the module documentation for the differences.
  """
  defmacro step(pattern, context_var \\ {:_, [], nil}, do: block) do
    # Generate collision-free function name using sequential counter
    count = Module.get_attribute(__CALLER__.module, :cucumber_step_count) || 0
    Module.put_attribute(__CALLER__.module, :cucumber_step_count, count + 1)
    fun_name = :"step_#{count}"

    quote do
      # Store metadata about this step
      @cucumber_steps {unquote(pattern),
                       %{
                         function: unquote(fun_name),
                         line: unquote(__CALLER__.line),
                         file: unquote(__CALLER__.file)
                       }}

      # Define the actual step function
      def unquote(fun_name)(unquote(context_var)) do
        unquote(block)
      end
    end
  end

  defmacro __before_compile__(env) do
    steps =
      Module.get_attribute(env.module, :cucumber_steps, [])
      |> Enum.reverse()

    # Note: step matching and dispatch happen in Cucumber.Runtime via the
    # step registry — there is deliberately no per-module dispatcher, so
    # matching semantics (including ambiguity detection) live in one place.
    quote do
      # Make steps available for discovery
      def __cucumber_steps__ do
        unquote(Macro.escape(steps))
      end
    end
  end
end
