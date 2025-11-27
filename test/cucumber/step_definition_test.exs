defmodule Cucumber.StepDefinitionTest do
  use ExUnit.Case, async: true

  describe "step macro" do
    test "registers step with pattern and metadata" do
      defmodule RegisterTestSteps do
        use Cucumber.StepDefinition

        step "I am registered", context do
          context
        end
      end

      steps = RegisterTestSteps.__cucumber_steps__()

      assert length(steps) == 1
      [{pattern, metadata}] = steps
      assert pattern == "I am registered"
      assert is_atom(metadata.function)
      assert is_integer(metadata.line)
      assert is_binary(metadata.file)
    end

    test "registers multiple steps in definition order" do
      defmodule MultiStepModule do
        use Cucumber.StepDefinition

        step "first step", context do
          context
        end

        step "second step", context do
          context
        end

        step "third step", context do
          context
        end
      end

      steps = MultiStepModule.__cucumber_steps__()

      assert length(steps) == 3
      patterns = Enum.map(steps, fn {pattern, _} -> pattern end)
      assert patterns == ["first step", "second step", "third step"]
    end

    test "generates unique function names via hash" do
      defmodule UniqueFuncModule do
        use Cucumber.StepDefinition

        step "step one", context do
          context
        end

        step "step two", context do
          context
        end
      end

      steps = UniqueFuncModule.__cucumber_steps__()
      func_names = Enum.map(steps, fn {_, meta} -> meta.function end)

      assert length(Enum.uniq(func_names)) == length(func_names)

      # Function names follow the pattern step_<hash>
      Enum.each(func_names, fn name ->
        assert Atom.to_string(name) =~ ~r/^step_\d+$/
      end)
    end

    test "allows omitting context variable when not needed" do
      defmodule NoContextModule do
        use Cucumber.StepDefinition

        step "I have no context" do
          :ok
        end
      end

      steps = NoContextModule.__cucumber_steps__()
      assert length(steps) == 1

      result = NoContextModule.step(%{some: "data"}, "I have no context")
      assert result == :ok
    end
  end

  describe "generated step/2 function" do
    test "matches step text and returns result" do
      defmodule MatchingSteps do
        use Cucumber.StepDefinition

        step "I return a value", _context do
          %{returned: true}
        end
      end

      result = MatchingSteps.step(%{existing: "data"}, "I return a value")
      assert result == %{returned: true}
    end

    test "extracts parameters and passes via context.args" do
      defmodule ParameterSteps do
        use Cucumber.StepDefinition

        step "I have {int} items costing {float}", context do
          [count, price] = context.args
          %{count: count, price: price}
        end
      end

      result = ParameterSteps.step(%{}, "I have 5 items costing 19.99")
      assert result == %{count: 5, price: 19.99}
    end

    test "extracts string parameters" do
      defmodule StringParamSteps do
        use Cucumber.StepDefinition

        step "I enter {string} as username", context do
          [username] = context.args
          %{username: username}
        end
      end

      result = StringParamSteps.step(%{}, "I enter \"john_doe\" as username")
      assert result == %{username: "john_doe"}
    end

    test "raises when no step matches" do
      defmodule NoMatchSteps do
        use Cucumber.StepDefinition

        step "I exist", context do
          context
        end
      end

      assert_raise RuntimeError, ~r/No step definition found/, fn ->
        NoMatchSteps.step(%{}, "I do not exist")
      end
    end

    test "matches first defined step when multiple could match" do
      defmodule FirstMatchSteps do
        use Cucumber.StepDefinition

        step "I have {int} items", context do
          Map.put(context, :matched, :first)
        end

        step "I have 5 items", context do
          Map.put(context, :matched, :second)
        end
      end

      result = FirstMatchSteps.step(%{}, "I have 5 items")
      assert result.matched == :first
    end
  end

  describe "__cucumber_steps__/0" do
    test "returns list of {pattern, metadata} tuples" do
      defmodule MetadataSteps do
        use Cucumber.StepDefinition

        step "check metadata", context do
          context
        end
      end

      steps = MetadataSteps.__cucumber_steps__()

      assert is_list(steps)
      assert [{pattern, metadata}] = steps
      assert is_binary(pattern)
      assert is_map(metadata)
      assert Map.has_key?(metadata, :function)
      assert Map.has_key?(metadata, :line)
      assert Map.has_key?(metadata, :file)
    end

    test "captures correct line numbers" do
      defmodule LineNumberSteps do
        use Cucumber.StepDefinition

        step "line test", context do
          context
        end
      end

      [{_pattern, metadata}] = LineNumberSteps.__cucumber_steps__()
      assert metadata.line > 0
    end

    test "captures correct file path" do
      defmodule FilePathSteps do
        use Cucumber.StepDefinition

        step "file test", context do
          context
        end
      end

      [{_pattern, metadata}] = FilePathSteps.__cucumber_steps__()
      assert metadata.file =~ "step_definition_test.exs"
    end
  end
end
