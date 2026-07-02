defmodule Cucumber.DiscoveryTest do
  use ExUnit.Case

  alias Cucumber.Discovery

  describe "discover/1 with syntax errors" do
    test "propagates syntax errors during step discovery instead of silencing them" do
      temp_dir = Path.join(System.tmp_dir(), "discover_test_#{:rand.uniform(10_000)}")
      step_dir = Path.join(temp_dir, "step_definitions")
      File.mkdir_p!(step_dir)

      # Create a step file with syntax error
      invalid_file = Path.join(step_dir, "syntax_error.exs")

      File.write!(invalid_file, """
      defmodule SyntaxErrorSteps do
        use Cucumber.StepDefinition

        # Missing 'do' - syntax error
        step "I have syntax error", context
          context
        end
      end
      """)

      try do
        # Discovery should fail with syntax error, not return nil
        # This verifies the fix for not silencing import errors
        assert_raise SyntaxError, fn ->
          Discovery.discover(steps: [Path.join(step_dir, "*.exs")])
        end
      after
        File.rm_rf(temp_dir)
      end
    end

    test "successfully discovers valid step definitions" do
      temp_dir = Path.join(System.tmp_dir(), "discover_valid_test_#{:rand.uniform(10_000)}")
      step_dir = Path.join(temp_dir, "step_definitions")
      File.mkdir_p!(step_dir)

      # Create a valid step file
      valid_file = Path.join(step_dir, "valid_steps.exs")

      File.write!(valid_file, """
      defmodule ValidDiscoverySteps do
        use Cucumber.StepDefinition

        step "I am a valid step", context do
          context
        end
      end
      """)

      try do
        # Discovery should succeed
        result = Discovery.discover(steps: [Path.join(step_dir, "*.exs")])

        assert %Discovery.DiscoveryResult{} = result
        assert length(result.step_modules) == 1
        assert Map.has_key?(result.step_registry, {:expression, "I am a valid step"})
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 feature discovery" do
    test "discovers feature files from patterns" do
      temp_dir = Path.join(System.tmp_dir(), "feature_discover_#{:rand.uniform(10_000)}")
      File.mkdir_p!(temp_dir)

      feature_file = Path.join(temp_dir, "example.feature")

      File.write!(feature_file, """
      Feature: Example feature
        Scenario: Example scenario
          Given a step
      """)

      try do
        result = Discovery.discover(features: [Path.join(temp_dir, "*.feature")], steps: [])

        assert length(result.features) == 1
        [feature] = result.features
        assert feature.name == "Example feature"
        assert feature.file == feature_file
      after
        File.rm_rf(temp_dir)
      end
    end

    test "discovers multiple feature files" do
      temp_dir = Path.join(System.tmp_dir(), "multi_feature_#{:rand.uniform(10_000)}")
      File.mkdir_p!(temp_dir)

      File.write!(Path.join(temp_dir, "first.feature"), """
      Feature: First feature
        Scenario: First scenario
          Given a step
      """)

      File.write!(Path.join(temp_dir, "second.feature"), """
      Feature: Second feature
        Scenario: Second scenario
          Given another step
      """)

      try do
        result = Discovery.discover(features: [Path.join(temp_dir, "*.feature")], steps: [])

        assert length(result.features) == 2
        names = Enum.map(result.features, & &1.name) |> Enum.sort()
        assert names == ["First feature", "Second feature"]
      after
        File.rm_rf(temp_dir)
      end
    end

    test "discovers Markdown feature files alongside plain ones, each with its own parser" do
      temp_dir = Path.join(System.tmp_dir(), "md_feature_#{:rand.uniform(10_000)}")
      File.mkdir_p!(temp_dir)

      File.write!(Path.join(temp_dir, "plain.feature"), """
      Feature: Plain feature
        Scenario: Plain scenario
          Given a step
      """)

      File.write!(Path.join(temp_dir, "markdown.feature.md"), """
      # Feature: Markdown feature

      Prose the Markdown parser ignores.

      ## Scenario: Markdown scenario

      * Given a step
      """)

      try do
        # The same two-pattern shape as the discovery defaults.
        result =
          Discovery.discover(
            features: [Path.join(temp_dir, "*.feature"), Path.join(temp_dir, "*.feature.md")],
            steps: []
          )

        names = Enum.map(result.features, & &1.name) |> Enum.sort()
        assert names == ["Markdown feature", "Plain feature"]

        markdown = Enum.find(result.features, &(&1.name == "Markdown feature"))
        assert [%{steps: [%{text: "a step"}]}] = markdown.scenarios
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 step registry" do
    test "builds registry with module and metadata" do
      temp_dir = Path.join(System.tmp_dir(), "registry_test_#{:rand.uniform(10_000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      File.write!(Path.join(step_dir, "my_steps.exs"), """
      defmodule RegistryTestSteps#{:rand.uniform(10_000)} do
        use Cucumber.StepDefinition

        step "I have {int} items", context do
          context
        end
      end
      """)

      try do
        result = Discovery.discover(steps: [Path.join(step_dir, "*.exs")])

        assert Map.has_key?(result.step_registry, {:expression, "I have {int} items"})
        {module, metadata} = result.step_registry[{:expression, "I have {int} items"}]
        assert is_atom(module)
        assert is_map(metadata)
        assert Map.has_key?(metadata, :line)
        assert Map.has_key?(metadata, :file)
      after
        File.rm_rf(temp_dir)
      end
    end

    test "combines steps from multiple modules" do
      temp_dir = Path.join(System.tmp_dir(), "multi_module_#{:rand.uniform(10_000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      rand_suffix = :rand.uniform(10_000)

      File.write!(Path.join(step_dir, "first_steps.exs"), """
      defmodule FirstModuleSteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "step from first module", context do
          context
        end
      end
      """)

      File.write!(Path.join(step_dir, "second_steps.exs"), """
      defmodule SecondModuleSteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "step from second module", context do
          context
        end
      end
      """)

      try do
        result = Discovery.discover(steps: [Path.join(step_dir, "*.exs")])

        assert length(result.step_modules) == 2
        assert Map.has_key?(result.step_registry, {:expression, "step from first module"})
        assert Map.has_key?(result.step_registry, {:expression, "step from second module"})
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 duplicate step detection" do
    test "raises on duplicate step definitions" do
      temp_dir = Path.join(System.tmp_dir(), "duplicate_test_#{:rand.uniform(10_000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      rand_suffix = :rand.uniform(10_000)

      File.write!(Path.join(step_dir, "a_steps.exs"), """
      defmodule DuplicateASteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "I am duplicated", context do
          context
        end
      end
      """)

      File.write!(Path.join(step_dir, "b_steps.exs"), """
      defmodule DuplicateBSteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "I am duplicated", context do
          context
        end
      end
      """)

      try do
        assert_raise RuntimeError, ~r/Duplicate step definition/, fn ->
          Discovery.discover(steps: [Path.join(step_dir, "*.exs")])
        end
      after
        File.rm_rf(temp_dir)
      end
    end

    test "raises on duplicate regex step definitions" do
      temp_dir = Path.join(System.tmp_dir(), "duplicate_regex_test_#{:rand.uniform(10_000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      rand_suffix = :rand.uniform(10_000)

      File.write!(Path.join(step_dir, "a_steps.exs"), """
      defmodule DuplicateRegexASteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step ~r/^I am duplicated$/, context do
          context
        end
      end
      """)

      File.write!(Path.join(step_dir, "b_steps.exs"), """
      defmodule DuplicateRegexBSteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step ~r/^I am duplicated$/, context do
          context
        end
      end
      """)

      try do
        assert_raise RuntimeError, ~r/Duplicate step definition.*I am duplicated/s, fn ->
          Discovery.discover(steps: [Path.join(step_dir, "*.exs")])
        end
      after
        File.rm_rf(temp_dir)
      end
    end

    test "duplicate error includes file and line information" do
      temp_dir = Path.join(System.tmp_dir(), "dup_info_test_#{:rand.uniform(10_000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      rand_suffix = :rand.uniform(10_000)

      File.write!(Path.join(step_dir, "first.exs"), """
      defmodule DupInfoFirst#{rand_suffix} do
        use Cucumber.StepDefinition

        step "duplicate pattern", context do
          context
        end
      end
      """)

      File.write!(Path.join(step_dir, "second.exs"), """
      defmodule DupInfoSecond#{rand_suffix} do
        use Cucumber.StepDefinition

        step "duplicate pattern", context do
          context
        end
      end
      """)

      try do
        error =
          assert_raise RuntimeError, fn ->
            Discovery.discover(steps: [Path.join(step_dir, "*.exs")])
          end

        assert error.message =~ "First defined in:"
        assert error.message =~ "Also defined in:"
        assert error.message =~ "duplicate pattern"
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 with hook errors" do
    test "propagates syntax errors during hook discovery" do
      temp_dir = Path.join(System.tmp_dir(), "hook_error_test_#{:rand.uniform(10_000)}")
      support_dir = Path.join(temp_dir, "support")
      File.mkdir_p!(support_dir)

      invalid_file = Path.join(support_dir, "bad_hooks.exs")

      File.write!(invalid_file, """
      defmodule BadHooks do
        use Cucumber.Hooks

        before_scenario context
          {:ok, context}
        end
      end
      """)

      try do
        assert_raise SyntaxError, fn ->
          Discovery.discover(
            support: [Path.join(support_dir, "*.exs")],
            steps: [],
            features: []
          )
        end
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 with feature parse errors" do
    test "propagates parse errors from invalid feature files" do
      temp_dir = Path.join(System.tmp_dir(), "feature_error_test_#{:rand.uniform(10_000)}")
      File.mkdir_p!(temp_dir)

      invalid_file = Path.join(temp_dir, "invalid.feature")
      File.write!(invalid_file, "This is not valid Gherkin at all")

      try do
        assert_raise Gherkin.ParseError, fn ->
          Discovery.discover(
            features: [Path.join(temp_dir, "*.feature")],
            steps: [],
            support: []
          )
        end
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 repeated discovery" do
    test "returns the same results when files were already loaded" do
      temp_dir = Path.join(System.tmp_dir(), "rediscover_test_#{:rand.uniform(10_000)}")
      step_dir = Path.join(temp_dir, "steps")
      support_dir = Path.join(temp_dir, "support")
      File.mkdir_p!(step_dir)
      File.mkdir_p!(support_dir)

      rand_suffix = :rand.uniform(10_000)

      File.write!(Path.join(step_dir, "steps.exs"), """
      defmodule RediscoverSteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "a rediscovered step", context do
          context
        end
      end
      """)

      File.write!(Path.join(support_dir, "hooks.exs"), """
      defmodule RediscoverHooks#{rand_suffix} do
        use Cucumber.Hooks

        before_scenario context do
          {:ok, context}
        end
      end
      """)

      opts = [
        steps: [Path.join(step_dir, "*.exs")],
        support: [Path.join(support_dir, "*.exs")],
        features: []
      ]

      try do
        first = Discovery.discover(opts)
        # Code.require_file/1 returns nil for already-loaded files, so a
        # second pass must serve modules from the cache instead of crashing
        # or dropping them
        second = Discovery.discover(opts)

        assert second.step_modules == first.step_modules
        assert second.step_registry == first.step_registry
        assert second.hook_modules == first.hook_modules
        assert Map.has_key?(second.step_registry, {:expression, "a rediscovered step"})
      after
        File.rm_rf(temp_dir)
      end
    end

    test "serves the cache when a later pass spells the path differently" do
      temp_dir = Path.join(System.tmp_dir(), "respell_test_#{:rand.uniform(10_000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      rand_suffix = :rand.uniform(10_000)

      File.write!(Path.join(step_dir, "steps.exs"), """
      defmodule RespellSteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "a respelled step", context do
          context
        end
      end
      """)

      base_opts = [support: [], features: []]

      try do
        first = Discovery.discover([{:steps, [Path.join(step_dir, "*.exs")]} | base_opts])

        # Code.require_file/1 dedupes on the expanded path, so a different
        # spelling of the same file must hit the same cache entry
        respelled_pattern = Path.join([temp_dir, ".", "steps", "*.exs"])
        second = Discovery.discover([{:steps, [respelled_pattern]} | base_opts])

        assert second.step_modules == first.step_modules
        assert Map.has_key?(second.step_registry, {:expression, "a respelled step"})
      after
        File.rm_rf(temp_dir)
      end
    end

    test "fails loudly when a file was loaded by someone other than discovery" do
      temp_dir = Path.join(System.tmp_dir(), "preloaded_test_#{:rand.uniform(10_000)}")
      step_dir = Path.join(temp_dir, "steps")
      File.mkdir_p!(step_dir)

      rand_suffix = :rand.uniform(10_000)
      step_file = Path.join(step_dir, "steps.exs")

      File.write!(step_file, """
      defmodule PreloadedSteps#{rand_suffix} do
        use Cucumber.StepDefinition

        step "a preloaded step", context do
          context
        end
      end
      """)

      try do
        Code.require_file(step_file)

        # Discovery can't know which modules the earlier load defined, so it
        # must not silently produce an empty registry
        assert_raise RuntimeError, ~r/already loaded before Cucumber discovery/, fn ->
          Discovery.discover(
            steps: [Path.join(step_dir, "*.exs")],
            support: [],
            features: []
          )
        end
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  describe "discover/1 with empty patterns" do
    test "returns empty results for non-matching patterns" do
      result =
        Discovery.discover(
          features: ["nonexistent/**/*.feature"],
          steps: ["nonexistent/**/*.exs"],
          support: ["nonexistent/**/*.exs"]
        )

      assert result.features == []
      assert result.step_modules == []
      assert result.step_registry == %{}
      assert result.hook_modules == []
    end
  end
end
