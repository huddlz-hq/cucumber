defmodule Cucumber.Compiler do
  @moduledoc false

  # Compiles discovered features and steps into ExUnit test modules.
  #
  # The compilation pipeline works as follows:
  #
  # 1. Discovery finds all feature files and step definitions via `Cucumber.Discovery`
  # 2. For each feature file, a unique ExUnit test module is generated
  # 3. Module names are derived from the feature file path
  #    (e.g., `test/features/auth.feature` becomes `Test.Features.AuthTest`)
  # 4. The feature is compiled into pickles by `Gherkin.Pickles` (expanding
  #    scenario outlines and rules); each pickle becomes one ExUnit `test`
  #    block carrying its pickle id
  # 5. Tags from features and scenarios are mapped to ExUnit tags for filtering
  # 6. Hooks are wired in via `Cucumber.Hooks`

  alias Cucumber.Discovery
  alias Cucumber.Messages.Emitter

  @doc """
  Compiles all discovered features into ExUnit test modules.
  """
  @spec compile_features!(keyword()) :: [module()]
  def compile_features!(opts \\ []) do
    # Discover features and steps
    %Discovery.DiscoveryResult{
      features: features,
      step_registry: step_registry,
      hook_modules: hook_modules
    } = Discovery.discover(opts)

    # Start the run-wide coordinator before any test executes, or join the
    # run in progress when another compile_features! call started it
    Cucumber.RunCoordinator.start_or_join()

    compile_all!(
      features,
      step_registry,
      hook_modules,
      Application.get_env(:cucumber, :messages)
    )
  end

  @doc false
  # Compiles a list of parsed features (each carrying :file and :source, as
  # set by discovery) into test modules, threading the pickle id sequence so
  # ids are unique across the whole run — the messages stream references
  # them run-wide. When `messages_path` is set, builds the run's static
  # envelopes and turns on the coordinator's message recorder; the runner and the
  # after_suite flush do the rest. Shared by compile_features!/1 and
  # Cucumber.BehaviorCase.
  @spec compile_all!([map()], Cucumber.StepRegistry.t(), [module()], String.t() | nil) ::
          [module()]
  def compile_all!(features, step_registry, hook_modules, messages_path) do
    register_after_suite_callback()
    reject_module_name_collisions!(features)

    hooks = Cucumber.Hooks.collect_hooks(hook_modules)

    case Emitter.prepare_features(features, step_registry, hooks, messages_path) do
      [] ->
        []

      pairs ->
        runtime_key = register_compilation(step_registry, hooks)

        Enum.map(pairs, fn {feature, compilation} ->
          define_feature!(feature, runtime_key, compilation)
        end)
    end
  end

  @doc false
  # Public so test harnesses (e.g. Cucumber.BehaviorCase) can compile a single
  # parsed feature against an explicit step registry, bypassing discovery.
  # The feature must carry a `:file` key (as set by Cucumber.Discovery).
  # `:compilation` accepts a precomputed `Gherkin.Pickles.Compilation` (used
  # by compile_features!/1 to thread run-unique pickle ids across features).
  @spec compile_feature!(map(), Cucumber.StepRegistry.t(), [module()], keyword()) :: module()
  def compile_feature!(feature, step_registry, hook_modules, opts \\ []) do
    compilation =
      Keyword.get_lazy(opts, :compilation, fn -> Gherkin.Pickles.compile(feature) end)

    register_after_suite_callback()
    runtime_key = register_compilation(step_registry, Cucumber.Hooks.collect_hooks(hook_modules))
    define_feature!(feature, runtime_key, compilation)
  end

  defp register_compilation(registry, hooks) do
    Cucumber.RunCoordinator.register_after_all(hooks)
    Cucumber.RunCoordinator.register_compilation(registry, hooks)
  end

  defp define_feature!(feature, runtime_key, compilation) do
    warn_on_empty_feature(feature)

    # Generate module name from feature file path
    module_name = generate_module_name(feature.file)

    # Check if feature has @async tag
    async = "async" in feature.tags

    # Generate test module AST
    ast =
      quote do
        defmodule unquote(module_name) do
          use ExUnit.Case, async: unquote(async)

          # Tag with cucumber and feature name
          @moduletag :cucumber
          @moduletag unquote(feature_tag(feature.name))

          # Add feature tags as module tags (except reserved ones)
          unquote_splicing(
            for tag <- feature.tags, tag != "async" do
              quote do: @moduletag(unquote(String.to_atom(tag)))
            end
          )

          @doc false
          def __cucumber_runtime__ do
            Cucumber.RunCoordinator.runtime_data!(unquote(Macro.escape(runtime_key)))
          end

          # One test per pickle (outlines and rules expanded by Gherkin.Pickles)
          unquote_splicing(
            for pickle <- compilation.pickles do
              generate_scenario_test(pickle, feature, async)
            end
          )
        end
      end

    # Compile the module
    [{^module_name, _}] = Code.compile_quoted(ast, feature.file)
    module_name
  end

  @doc false
  # Public for testing. Emits a compile-time warning when a feature parses with
  # zero scenarios — usually a sign the parser silently dropped them. The
  # synthetic stacktrace makes editors highlight the warning on the feature
  # file itself rather than inside the cucumber library.
  def warn_on_empty_feature(%{scenarios: []} = feature) do
    if Map.get(feature, :rules, []) == [] do
      stacktrace = [
        {__MODULE__, :compile_feature, 3, [file: String.to_charlist(feature.file), line: 1]}
      ]

      IO.warn(
        "Cucumber: feature file #{feature.file} parsed with zero scenarios — " <>
          "scenarios may have been silently dropped by the parser.",
        stacktrace
      )
    else
      :ok
    end
  end

  def warn_on_empty_feature(_feature), do: :ok

  @after_suite_key {Cucumber, :after_suite_registered}

  defp register_after_suite_callback do
    unless :persistent_term.get(@after_suite_key, false) do
      :global.trans({@after_suite_key, self()}, &install_after_suite_callback/0, [node()])
    end
  end

  defp install_after_suite_callback do
    unless :persistent_term.get(@after_suite_key, false) do
      ExUnit.after_suite(&finish_run/1)
      :persistent_term.put(@after_suite_key, true)
    end
  end

  defp finish_run(suite_result) do
    try do
      Cucumber.RunCoordinator.run_after_all(suite_result)
    after
      Cucumber.RunCoordinator.flush_messages(suite_result)
    end

    Cucumber.RunCoordinator.end_run(suite_result)
  catch
    kind, reason ->
      Cucumber.RunCoordinator.end_run()
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Two feature files can generate the same test module — `checkout.feature`
  # and `checkout.feature.md` in one directory both map to
  # Test.Features.CheckoutTest. Compiling both would silently redefine the
  # module, dropping the first file's scenarios from the run, so fail loudly
  # instead (like discovery does for duplicate step definitions).
  defp reject_module_name_collisions!(features) do
    features
    |> Enum.group_by(&generate_module_name(&1.file))
    |> Enum.each(fn
      {_module, [_feature]} ->
        :ok

      {module, features} ->
        files = features |> Enum.map(& &1.file) |> Enum.sort() |> Enum.join(" and ")

        raise ArgumentError,
              "feature files #{files} would generate the same test module " <>
                "#{module}. Rename one of them."
    end)
  end

  defp generate_module_name(file_path) do
    # Convert a path like "test/features/authentication.feature" (or
    # "authentication.feature.md") to Test.Features.AuthenticationTest.
    # Path.rootname/1 only strips the final extension, so reduce the
    # Markdown double extension to a single one first.
    file_path
    |> String.replace_suffix(".feature.md", ".feature")
    |> Path.rootname()
    |> Path.split()
    |> Enum.map_join(".", &Macro.camelize/1)
    |> Kernel.<>("Test")
    |> String.to_atom()
  end

  defp feature_tag(name) do
    # Convert "User Authentication" to :feature_user_authentication
    tag_name =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    :"feature_#{tag_name}"
  end

  defp generate_scenario_test(%Gherkin.Pickle{} = pickle, feature, async) do
    # Generate tags for the scenario (its own tags plus inherited rule /
    # outline / examples tags — feature tags are module tags)
    tags =
      pickle.own_tags
      |> Enum.map(&String.to_atom/1)
      |> Enum.map(fn tag -> quote do: @tag(unquote(tag)) end)

    name = test_name(pickle)

    # The whole scenario lifecycle (before hooks, background, steps, after
    # hooks) runs inside the test body via the runtime — see
    # Cucumber.Runtime.run_scenario/3.
    scenario_spec = %{
      feature_file: feature.file,
      feature_tags: feature.tags,
      # Scenario-level tags, distinguishable from feature tags (which become
      # @moduletag and are indistinguishable in the ExUnit context) — retry
      # tag precedence needs the two levels apart
      scenario_tags: pickle.own_tags,
      async: async,
      scenario_name: name,
      scenario_line: (pickle.scenario_line || 0) + 1,
      # Gherkin.PickleStep structs (step, pickle step id, from_background):
      # Cucumber.TestCase turns them into the test case's pickle steps
      pickle_steps: pickle.steps,
      pickle_id: pickle.id
    }

    quote do
      unquote_splicing(tags)
      @tag unquote(scenario_tag(name))
      @tag scenario_line: unquote((pickle.scenario_line || 0) + 1)

      test unquote(name), exunit_context do
        Cucumber.Runtime.run_scenario(
          exunit_context,
          unquote(Macro.escape(scenario_spec)),
          __cucumber_runtime__()
        )
      end
    end
  end

  # ExUnit raises on duplicate test names, so pickles from outline rows get
  # a row suffix and pickles inside rules a rule-name prefix (identically
  # named scenarios can appear in different rules). The pickle's own `name`
  # (placeholder-substituted, per the messages spec) is not unique.
  defp test_name(pickle) do
    base =
      case pickle.row_index do
        nil -> pickle.scenario_name
        row_index -> row_test_name(pickle.scenario_name, pickle.examples_name, row_index)
      end

    prefix_with_rule(pickle.rule_name, base)
  end

  defp row_test_name(outline_name, "", row_index), do: "#{outline_name} (row #{row_index})"

  defp row_test_name(outline_name, examples_name, row_index),
    do: "#{outline_name} (#{examples_name}: row #{row_index})"

  defp prefix_with_rule(nil, scenario_name), do: scenario_name
  defp prefix_with_rule("", scenario_name), do: scenario_name
  defp prefix_with_rule(rule_name, scenario_name), do: "#{rule_name}: #{scenario_name}"

  defp scenario_tag(name) do
    # Convert "User logs in successfully" to :scenario_user_logs_in_successfully
    tag_name =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    :"scenario_#{tag_name}"
  end
end
