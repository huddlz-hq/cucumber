defmodule Cucumber.HooksTest do
  use ExUnit.Case, async: true

  describe "duplicate hook detection" do
    test "raises CompileError when defining duplicate tagged hooks" do
      code = """
      defmodule DuplicateTaggedHooks do
        use Cucumber.Hooks

        before_scenario "@database", context do
          {:ok, context}
        end

        before_scenario "@database", context do
          {:ok, context}
        end
      end
      """

      assert_raise CompileError, ~r/Duplicate hook: before_scenario_database/, fn ->
        Code.compile_string(code)
      end
    end

    test "raises CompileError when defining duplicate global hooks" do
      code = """
      defmodule DuplicateGlobalHooks do
        use Cucumber.Hooks

        before_scenario context do
          {:ok, context}
        end

        before_scenario context do
          {:ok, context}
        end
      end
      """

      assert_raise CompileError, ~r/Duplicate hook: before_scenario_global/, fn ->
        Code.compile_string(code)
      end
    end

    test "allows different tags without error" do
      code = """
      defmodule DifferentTagsHooks do
        use Cucumber.Hooks

        before_scenario "@database", context do
          {:ok, context}
        end

        before_scenario "@admin", context do
          {:ok, context}
        end
      end
      """

      # Should compile without error
      assert [{DifferentTagsHooks, _}] = Code.compile_string(code)
    end
  end

  describe "hook filtering and execution" do
    test "filter_hooks returns global hooks and hooks matching tags" do
      defmodule FilterTestModule do
        def global_hook(context), do: {:ok, context}
        def database_hook(context), do: {:ok, context}
        def special_hook(context), do: {:ok, context}
      end

      hooks = [
        {:before_scenario, nil, {FilterTestModule, :global_hook}},
        {:before_scenario, "@database", {FilterTestModule, :database_hook}},
        {:before_scenario, "@special", {FilterTestModule, :special_hook}}
      ]

      # With ["database"] tags, should get global + @database hooks
      filtered = Cucumber.Hooks.filter_hooks(hooks, :before_scenario, ["database"])
      assert length(filtered) == 2

      # With ["database", "special"] tags, should get all 3 hooks
      filtered_all = Cucumber.Hooks.filter_hooks(hooks, :before_scenario, ["database", "special"])
      assert length(filtered_all) == 3

      # With [] tags, should only get global hook
      filtered_empty = Cucumber.Hooks.filter_hooks(hooks, :before_scenario, [])
      assert length(filtered_empty) == 1
    end

    test "run_before_hooks executes matching hooks and updates context" do
      defmodule RunTestModule do
        def hook_a(context), do: {:ok, Map.put(context, :hook_a, true)}
        def hook_b(context), do: {:ok, Map.put(context, :hook_b, true)}
      end

      hooks = [
        {:before_scenario, nil, {RunTestModule, :hook_a}},
        {:before_scenario, "@database", {RunTestModule, :hook_b}}
      ]

      # With database tag, both hooks run
      {:ok, result} = Cucumber.Hooks.run_before_hooks(hooks, %{}, ["database"])
      assert result.hook_a == true
      assert result.hook_b == true

      # Without database tag, only global hook runs
      {:ok, result_no_tag} = Cucumber.Hooks.run_before_hooks(hooks, %{}, [])
      assert result_no_tag.hook_a == true
      refute Map.has_key?(result_no_tag, :hook_b)
    end

    test "hooks run once per scenario with combined feature and scenario tags" do
      defmodule CombinedTagsModule do
        def count_hook(context) do
          count = Map.get(context, :hook_count, 0)
          {:ok, Map.put(context, :hook_count, count + 1)}
        end
      end

      hooks = [
        {:before_scenario, nil, {CombinedTagsModule, :count_hook}},
        {:before_scenario, "@database", {CombinedTagsModule, :count_hook}},
        {:before_scenario, "@special", {CombinedTagsModule, :count_hook}}
      ]

      # Scenario 1: feature has @database, scenario has no extra tags
      # Combined tags: ["database"]
      # Should run: global + @database = 2 hooks
      {:ok, scenario1} = Cucumber.Hooks.run_before_hooks(hooks, %{}, ["database"])
      assert scenario1.hook_count == 2

      # Scenario 2: feature has @database, scenario has @special
      # Combined tags: ["database", "special"]
      # Should run: global + @database + @special = 3 hooks
      {:ok, scenario2} = Cucumber.Hooks.run_before_hooks(hooks, %{}, ["database", "special"])
      assert scenario2.hook_count == 3
    end
  end
end
