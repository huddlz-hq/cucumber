defmodule Cucumber.ParameterTypesTest do
  use ExUnit.Case, async: true

  describe "parameter_type/2 registration" do
    test "registers types with name, regexp, and transform" do
      defmodule GoodTypes do
        use Cucumber.ParameterTypes

        parameter_type(:flight, regexp: ~r/[A-Z]{3}-[A-Z]{3}/, transform: &String.downcase/1)
        parameter_type("color", regexp: ~r/red|blue/)
      end

      types = GoodTypes.__cucumber_parameter_types__()

      assert %{regexp: %Regex{}, transform: transform} = types["flight"]
      assert is_function(transform, 1)
      assert %{regexp: %Regex{}, transform: nil} = types["color"]
    end

    test "shadowing a built-in type name raises at compile time" do
      assert_raise CompileError, ~r/shadows a built-in type/, fn ->
        defmodule ShadowTypes do
          use Cucumber.ParameterTypes

          parameter_type(:int, regexp: ~r/\d+/)
        end
      end
    end

    test "invalid type names raise at compile time" do
      assert_raise CompileError, ~r/invalid parameter type name/, fn ->
        defmodule BadNameTypes do
          use Cucumber.ParameterTypes

          parameter_type(:"has-dashes", regexp: ~r/x/)
        end
      end
    end

    test "a missing :regexp option raises at compile time" do
      assert_raise CompileError, ~r/requires a :regexp option/, fn ->
        defmodule NoRegexpTypes do
          use Cucumber.ParameterTypes

          parameter_type(:empty, transform: fn x -> x end)
        end
      end
    end

    test "defining the same type twice in one module raises at compile time" do
      assert_raise CompileError, ~r/defined more than once/, fn ->
        defmodule DuplicateTypes do
          use Cucumber.ParameterTypes

          parameter_type(:twice, regexp: ~r/a/)
          parameter_type(:twice, regexp: ~r/b/)
        end
      end
    end
  end
end
