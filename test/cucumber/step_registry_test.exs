defmodule Cucumber.StepRegistryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Cucumber.StepRegistry
  alias Cucumber.StepRegistry.Definition

  defmodule TopSteps do
    use Cucumber.StepDefinition

    step "a step at the top", context do
      context
    end
  end

  defmodule CukeSteps do
    use Cucumber.StepDefinition

    step "a cuke step", context do
      context
    end

    step "I have {int} cukes", context do
      context
    end
  end

  defmodule RegexSteps do
    use Cucumber.StepDefinition

    step ~r/^there are (\d+) cukes(?: in my (\w+))?(?: today)?$/, context do
      context
    end

    step ~r/no captures here/, context do
      context
    end

    step ~r/cukes in a jar/i, context do
      context
    end
  end

  defmodule ColorTypes do
    use Cucumber.ParameterTypes

    parameter_type(:color, regexp: ~r/red|blue/, transform: &String.upcase/1)
  end

  defmodule ColorSteps do
    use Cucumber.StepDefinition

    step "the light is {color}", context do
      context
    end
  end

  defmodule UndefinedTypeSteps do
    use Cucumber.StepDefinition

    step "the sky is {mood}", context do
      context
    end
  end

  defmodule DuplicateCukeSteps do
    use Cucumber.StepDefinition

    step "a cuke step", context do
      context
    end
  end

  defmodule DuplicateRegexSteps do
    use Cucumber.StepDefinition

    step ~r/no captures here/, context do
      context
    end
  end

  defmodule SameRegexOtherFlagsSteps do
    use Cucumber.StepDefinition

    step ~r/no captures here/i, context do
      context
    end
  end

  defmodule DuplicateColorTypes do
    use Cucumber.ParameterTypes

    parameter_type(:color, regexp: ~r/green/)
  end

  defmodule OverlappingSteps do
    use Cucumber.StepDefinition

    step "I have {int} {word}", context do
      context
    end

    step ~r/^I have (\d+) cukes$/, context do
      context
    end
  end

  describe "new/2" do
    test "orders definitions by file and line, whatever order the modules arrive in" do
      registry = StepRegistry.new([CukeSteps, TopSteps])

      assert [
               %Definition{position: 0, source: "a step at the top", module: TopSteps},
               %Definition{position: 1, source: "a cuke step", module: CukeSteps},
               %Definition{position: 2, source: "I have {int} cukes", module: CukeSteps}
             ] = StepRegistry.definitions(registry)
    end

    test "records where each definition lives and how to invoke it" do
      registry = StepRegistry.new([RegexSteps])

      [first | _] = StepRegistry.definitions(registry)

      assert first.kind == :regex
      assert first.source == "^there are (\\d+) cukes(?: in my (\\w+))?(?: today)?$"
      assert first.module == RegexSteps
      assert first.file == __ENV__.file
      assert is_integer(first.line)
      assert function_exported?(RegexSteps, first.function, 1)
    end

    test "rejects a step definition registered twice, naming both sites" do
      error =
        assert_raise RuntimeError, fn ->
          StepRegistry.new([CukeSteps, DuplicateCukeSteps])
        end

      assert error.message =~ "Duplicate step definition: 'a cuke step'"
      assert error.message =~ inspect(CukeSteps)
      assert error.message =~ inspect(DuplicateCukeSteps)
      assert error.message =~ ~r/#{Regex.escape(__ENV__.file)}:\d+/
    end

    test "rejects identical regexes, but not the same source with different flags" do
      assert_raise RuntimeError, ~r/Duplicate step definition: '~r\/no captures here\/'/, fn ->
        StepRegistry.new([RegexSteps, DuplicateRegexSteps])
      end

      registry = StepRegistry.new([DuplicateRegexSteps, SameRegexOtherFlagsSteps])
      assert length(StepRegistry.definitions(registry)) == 2
    end

    test "rejects a parameter type registered by more than one module" do
      assert_raise RuntimeError, ~r/Parameter type \{color\} is defined in more than one/, fn ->
        StepRegistry.new([ColorSteps], [ColorTypes, DuplicateColorTypes])
      end
    end

    test "drops a definition using an undefined parameter type, with a warning" do
      {registry, warning} =
        with_io(:stderr, fn -> StepRegistry.new([UndefinedTypeSteps, CukeSteps]) end)

      assert warning =~ ~s(step definition "the sky is {mood}")
      assert warning =~ "undefined parameter type {mood}"
      assert warning =~ "will be ignored"

      refute Enum.any?(StepRegistry.definitions(registry), &(&1.module == UndefinedTypeSteps))
      assert StepRegistry.match(registry, "the sky is grey") == :undefined
    end

    test "exposes the parameter types it was built with" do
      registry = StepRegistry.new([ColorSteps], [ColorTypes])

      assert %{"color" => %{name: "color", regexp: %Regex{}}} =
               StepRegistry.parameter_types(registry)
    end
  end

  describe "match/2" do
    test "matches a cucumber expression and converts typed args" do
      registry = StepRegistry.new([CukeSteps])

      assert {:ok, %Definition{source: "I have {int} cukes"}, [42]} =
               StepRegistry.match(registry, "I have 42 cukes")
    end

    test "applies custom parameter type transforms" do
      registry = StepRegistry.new([ColorSteps], [ColorTypes])

      assert {:ok, _definition, ["BLUE"]} = StepRegistry.match(registry, "the light is blue")
      assert StepRegistry.match(registry, "the light is green") == :undefined
    end

    test "returns :undefined when nothing matches" do
      registry = StepRegistry.new([CukeSteps])

      assert StepRegistry.match(registry, "nothing like this") == :undefined
    end

    test "regexes must match the whole step text" do
      registry = StepRegistry.new([RegexSteps])

      assert {:ok, _definition, []} = StepRegistry.match(registry, "no captures here")
      assert StepRegistry.match(registry, "there are no captures here at all") == :undefined
    end

    test "regex captures arrive as strings, with nil for unmatched optional groups" do
      registry = StepRegistry.new([RegexSteps])

      assert {:ok, _definition, ["3", "pocket"]} =
               StepRegistry.match(registry, "there are 3 cukes in my pocket")

      # The unmatched group is trailing: PCRE would drop it without an
      # explicit capture list
      assert {:ok, _definition, ["3", nil]} = StepRegistry.match(registry, "there are 3 cukes")
    end

    test "regex flags apply when matching" do
      registry = StepRegistry.new([RegexSteps])

      assert {:ok, _definition, []} = StepRegistry.match(registry, "CUKES IN A JAR")
    end

    test "reports every matching definition, in definition order, when ambiguous" do
      registry = StepRegistry.new([OverlappingSteps, CukeSteps])

      assert {:ambiguous, [{first, first_args}, {second, second_args}, {third, third_args}]} =
               StepRegistry.match(registry, "I have 3 cukes")

      assert [first.position, second.position, third.position] ==
               Enum.sort([first.position, second.position, third.position])

      assert {first.source, first_args} == {"I have {int} cukes", [3]}
      assert {second.source, second_args} == {"I have {int} {word}", [3, "cukes"]}
      assert {third.source, third_args} == {"^I have (\\d+) cukes$", ["3"]}
    end
  end

  describe "resolve/2 and args/2" do
    defmodule ExplodingTypes do
      use Cucumber.ParameterTypes

      parameter_type(:color,
        regexp: ~r/red|blue/,
        transform: fn _ -> raise "transform ran" end
      )
    end

    test "resolve/2 finds the definitions match/2 would, without converting args" do
      registry = StepRegistry.new([OverlappingSteps, CukeSteps, RegexSteps])

      for text <- ["I have 3 cukes", "there are 3 cukes", "no captures here", "nothing"] do
        expected =
          case StepRegistry.match(registry, text) do
            {:ok, definition, _args} -> {:ok, definition}
            :undefined -> :undefined
            {:ambiguous, matches} -> {:ambiguous, Enum.map(matches, &elem(&1, 0))}
          end

        assert StepRegistry.resolve(registry, text) == expected
      end
    end

    test "resolve/2 never runs a custom parameter type's transform" do
      registry = StepRegistry.new([ColorSteps], [ExplodingTypes])

      assert {:ok, %Definition{source: "the light is {color}"}} =
               StepRegistry.resolve(registry, "the light is red")

      assert StepRegistry.resolve(registry, "the light is green") == :undefined
    end

    test "args/2 converts the resolved definition's args, running transforms" do
      registry = StepRegistry.new([ColorSteps, RegexSteps], [ColorTypes])

      {:ok, color} = StepRegistry.resolve(registry, "the light is blue")
      assert StepRegistry.args(color, "the light is blue") == ["BLUE"]

      {:ok, regex} = StepRegistry.resolve(registry, "there are 3 cukes")
      assert StepRegistry.args(regex, "there are 3 cukes") == ["3", nil]
    end
  end

  describe "Definition.display_pattern/1" do
    test "shows expressions as written and regexes as sigils, flags included" do
      registry = StepRegistry.new([CukeSteps, RegexSteps])

      displays = registry |> StepRegistry.definitions() |> Enum.map(&Definition.display_pattern/1)

      assert "I have {int} cukes" in displays
      assert "~r/no captures here/" in displays
      assert "~r/cukes in a jar/i" in displays
    end
  end
end
