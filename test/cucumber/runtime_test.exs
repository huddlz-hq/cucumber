defmodule Cucumber.RuntimeTest do
  use ExUnit.Case, async: true

  alias Cucumber.Runtime
  alias Gherkin.Step

  # Test step module that returns various results
  defmodule TestSteps do
    use Cucumber.StepDefinition

    step "I return ok", _context do
      :ok
    end

    step "I return a map with {string}", %{args: [key]} = context do
      %{custom_key: key, original: context.feature_file}
    end

    step "I return a keyword list", _context do
      [keyword_key: "keyword_value", another: 123]
    end

    step "I return ok tuple with map", _context do
      {:ok, %{tuple_key: "tuple_value"}}
    end

    step "I return ok tuple with keyword", _context do
      {:ok, [tuple_keyword: "from_tuple"]}
    end

    step "I return error tuple", _context do
      {:error, "something went wrong"}
    end

    step "I return invalid value", _context do
      "invalid string return"
    end

    step "I have {int} items", %{args: [count]} = context do
      Map.put(context, :item_count, count)
    end

    step "I access the datatable", context do
      # Just return context to verify datatable was added
      context
    end

    step "I access the docstring", context do
      # Just return context to verify docstring was added
      context
    end
  end

  setup do
    step_registry = %{
      "I return ok" => {TestSteps, %{}},
      "I return a map with {string}" => {TestSteps, %{}},
      "I return a keyword list" => {TestSteps, %{}},
      "I return ok tuple with map" => {TestSteps, %{}},
      "I return ok tuple with keyword" => {TestSteps, %{}},
      "I return error tuple" => {TestSteps, %{}},
      "I return invalid value" => {TestSteps, %{}},
      "I have {int} items" => {TestSteps, %{}},
      "I access the datatable" => {TestSteps, %{}},
      "I access the docstring" => {TestSteps, %{}}
    }

    base_context = %{
      feature_file: "test/features/example.feature",
      scenario_name: "Test scenario"
    }

    {:ok, step_registry: step_registry, base_context: base_context}
  end

  describe "execute_step/3 return value handling" do
    test "handles :ok return by keeping context unchanged", ctx do
      step = %Step{keyword: "Given", text: "I return ok", line: 1}

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      assert result.feature_file == "test/features/example.feature"
      assert result.scenario_name == "Test scenario"
      assert [^step] = result.step_history
    end

    test "handles map return by merging into context", ctx do
      step = %Step{keyword: "When", text: "I return a map with \"test_value\"", line: 2}

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      assert result.custom_key == "test_value"
      assert result.original == "test/features/example.feature"
      assert result.feature_file == "test/features/example.feature"
    end

    test "handles keyword list return by merging into context", ctx do
      step = %Step{keyword: "When", text: "I return a keyword list", line: 3}

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      assert result.keyword_key == "keyword_value"
      assert result.another == 123
    end

    test "handles {:ok, map} return by merging into context", ctx do
      step = %Step{keyword: "When", text: "I return ok tuple with map", line: 4}

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      assert result.tuple_key == "tuple_value"
    end

    test "handles {:ok, keyword} return by merging into context", ctx do
      step = %Step{keyword: "When", text: "I return ok tuple with keyword", line: 5}

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      assert result.tuple_keyword == "from_tuple"
    end

    test "raises on {:error, reason} return", ctx do
      step = %Step{keyword: "When", text: "I return error tuple", line: 6}

      error =
        assert_raise Cucumber.StepError, fn ->
          Runtime.execute_step(ctx.base_context, step, ctx.step_registry)
        end

      assert error.message =~ "something went wrong"
    end

    test "raises on invalid return value", ctx do
      step = %Step{keyword: "When", text: "I return invalid value", line: 7}

      error =
        assert_raise Cucumber.StepError, fn ->
          Runtime.execute_step(ctx.base_context, step, ctx.step_registry)
        end

      assert error.message =~ "Invalid step return value"
    end
  end

  describe "execute_step/3 parameter extraction" do
    test "extracts and passes parameters via context.args", ctx do
      step = %Step{keyword: "Given", text: "I have 42 items", line: 1}

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      assert result.item_count == 42
      assert result.args == [42]
    end
  end

  describe "execute_step/3 step history" do
    test "tracks steps in step_history", ctx do
      step1 = %Step{keyword: "Given", text: "I return ok", line: 1}
      step2 = %Step{keyword: "When", text: "I return ok", line: 2}

      result1 = Runtime.execute_step(ctx.base_context, step1, ctx.step_registry)
      result2 = Runtime.execute_step(result1, step2, ctx.step_registry)

      assert [^step1, ^step2] = result2.step_history
    end

    test "initializes step_history if not present", ctx do
      context_without_history = Map.delete(ctx.base_context, :step_history)
      step = %Step{keyword: "Given", text: "I return ok", line: 1}

      result = Runtime.execute_step(context_without_history, step, ctx.step_registry)

      assert [^step] = result.step_history
    end
  end

  describe "execute_step/3 datatable handling" do
    test "attaches multi-row datatable with headers", ctx do
      datatable = [
        ["name", "age"],
        ["Alice", "30"],
        ["Bob", "25"]
      ]

      step = %Step{
        keyword: "Given",
        text: "I access the datatable",
        line: 1,
        datatable: datatable,
        docstring: nil
      }

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      assert result.datatable.headers == ["name", "age"]
      assert result.datatable.rows == [["Alice", "30"], ["Bob", "25"]]
      assert result.datatable.raw == datatable

      assert result.datatable.maps == [
               %{"name" => "Alice", "age" => "30"},
               %{"name" => "Bob", "age" => "25"}
             ]
    end

    test "attaches single-row datatable without headers", ctx do
      datatable = [["value1", "value2"]]

      step = %Step{
        keyword: "Given",
        text: "I access the datatable",
        line: 1,
        datatable: datatable,
        docstring: nil
      }

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      assert result.datatable.headers == []
      assert result.datatable.rows == [["value1", "value2"]]
      assert result.datatable.maps == []
      assert result.datatable.raw == datatable
    end

    test "does not add datatable key when nil", ctx do
      step = %Step{
        keyword: "Given",
        text: "I access the datatable",
        line: 1,
        datatable: nil,
        docstring: nil
      }

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      refute Map.has_key?(result, :datatable)
    end
  end

  describe "execute_step/3 docstring handling" do
    test "attaches docstring to context", ctx do
      step = %Step{
        keyword: "Given",
        text: "I access the docstring",
        line: 1,
        datatable: nil,
        docstring: "This is a\nmulti-line\ndocstring"
      }

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      assert result.docstring == "This is a\nmulti-line\ndocstring"
    end

    test "does not add docstring key when nil", ctx do
      step = %Step{
        keyword: "Given",
        text: "I access the docstring",
        line: 1,
        datatable: nil,
        docstring: nil
      }

      result = Runtime.execute_step(ctx.base_context, step, ctx.step_registry)

      refute Map.has_key?(result, :docstring)
    end
  end

  describe "execute_step/3 missing step definition" do
    test "raises StepError for undefined step", ctx do
      step = %Step{keyword: "Given", text: "I do not exist", line: 1}

      error =
        assert_raise Cucumber.StepError, fn ->
          Runtime.execute_step(ctx.base_context, step, ctx.step_registry)
        end

      assert error.message =~ "No matching step definition"
      assert error.message =~ "I do not exist"
    end
  end
end
