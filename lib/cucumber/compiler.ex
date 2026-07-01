defmodule Cucumber.Compiler do
  @moduledoc """
  Compiles discovered features and steps into ExUnit test modules.

  The compilation pipeline works as follows:

  1. Discovery finds all feature files and step definitions via `Cucumber.Discovery`
  2. For each feature file, a unique ExUnit test module is generated
  3. Module names are derived from the feature file path
     (e.g., `test/features/auth.feature` becomes `Test.Features.AuthTest`)
  4. The feature is compiled into pickles by `Gherkin.Pickles` (expanding
     scenario outlines and rules); each pickle becomes one ExUnit `test`
     block carrying its pickle id
  5. Tags from features and scenarios are mapped to ExUnit tags for filtering
  6. Hooks are wired in via `Cucumber.Hooks`
  """

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
      hook_modules: hook_modules,
      parameter_types: parameter_types
    } = Discovery.discover(opts)

    # Start (or reset) the run-wide coordinator before any test executes
    Cucumber.RunCoordinator.ensure_started()

    compile_all!(
      features,
      step_registry,
      hook_modules,
      parameter_types,
      Application.get_env(:cucumber, :messages)
    )
  end

  @doc false
  # Compiles a list of parsed features (each carrying :file and :source, as
  # set by discovery) into test modules, threading the pickle id sequence so
  # ids are unique across the whole run — the messages stream references
  # them run-wide. When `messages_path` is set, builds the run's static
  # envelopes and enables the coordinator's message sink; the runner and the
  # after_suite flush do the rest. Shared by compile_features!/1 and
  # Cucumber.BehaviorCase.
  @spec compile_all!([map()], map(), [module()], map(), String.t() | nil) :: [module()]
  def compile_all!(features, step_registry, hook_modules, parameter_types, messages_path) do
    {compiled, next_id} =
      Enum.map_reduce(features, 0, fn feature, start_id ->
        compilation = Gherkin.Pickles.compile(feature, start_id)

        module =
          compile_feature!(feature, step_registry, hook_modules,
            parameter_types: parameter_types,
            compilation: compilation
          )

        {{module, feature, compilation}, compilation.next_id}
      end)

    if messages_path do
      Emitter.configure(
        messages_path,
        Enum.map(compiled, fn {_module, feature, compilation} -> {feature, compilation} end),
        step_registry,
        Cucumber.Hooks.collect_hooks(hook_modules),
        parameter_types,
        next_id
      )
    end

    Enum.map(compiled, fn {module, _feature, _compilation} -> module end)
  end

  @doc false
  # Public so test harnesses (e.g. Cucumber.BehaviorCase) can compile a single
  # parsed feature against an explicit step registry, bypassing discovery.
  # The feature must carry a `:file` key (as set by Cucumber.Discovery).
  # `:compilation` accepts a precomputed `Gherkin.Pickles.Compilation` (used
  # by compile_features!/1 to thread run-unique pickle ids across features).
  @spec compile_feature!(map(), map(), [module()], keyword()) :: module()
  def compile_feature!(feature, step_registry, hook_modules, opts \\ []) do
    warn_on_empty_feature(feature)

    parameter_types = Keyword.get(opts, :parameter_types, %{})

    compilation =
      Keyword.get_lazy(opts, :compilation, fn -> Gherkin.Pickles.compile(feature) end)

    # Generate module name from feature file path
    module_name = generate_module_name(feature.file)

    # Check if feature has @async tag
    async = "async" in feature.tags

    # Collect all hooks
    all_hooks = Cucumber.Hooks.collect_hooks(hook_modules)

    # Run-level teardown: hand the after_all hooks to the coordinator and
    # make sure the after_suite callback that claims them is registered.
    # The callback is registered once per VM because ExUnit.after_suite
    # callbacks accumulate in config and fire on every ExUnit.run.
    Cucumber.RunCoordinator.register_after_all(all_hooks)
    register_after_suite_callback()

    # The registry and hook list live in :persistent_term rather than being
    # Macro.escape'd into every generated module (which bloats each module's
    # AST with a full copy). Keys are unique per compilation, so repeated
    # compiles (mix test.watch, test harnesses) can't see stale data.
    runtime_key = {Cucumber, :runtime_data, :erlang.unique_integer([:positive])}

    :persistent_term.put(runtime_key, %{
      step_registry: step_registry,
      hooks: all_hooks,
      parameter_types: parameter_types
    })

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

          # Runtime data accessors (registry and hooks live in :persistent_term)
          def __step_registry__ do
            :persistent_term.get(unquote(Macro.escape(runtime_key))).step_registry
          end

          @doc false
          def __cucumber_feature_hooks__ do
            :persistent_term.get(unquote(Macro.escape(runtime_key))).hooks
          end

          @doc false
          def __cucumber_parameter_types__ do
            :persistent_term.get(unquote(Macro.escape(runtime_key))).parameter_types
          end

          @doc false
          def __cucumber_runtime__ do
            :persistent_term.get(unquote(Macro.escape(runtime_key)))
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

  defp register_after_suite_callback do
    unless :persistent_term.get({Cucumber, :after_suite_registered}, false) do
      # One callback for both run-level concerns so their order is fixed:
      # after_all hooks run first (their testRunHook messages must land in
      # the stream), then the message flush — which must happen even when an
      # after_all hook raises (the raise still fails the run).
      ExUnit.after_suite(fn suite_result ->
        try do
          Cucumber.RunCoordinator.run_after_all(suite_result)
        after
          Cucumber.RunCoordinator.flush_messages(suite_result)
        end
      end)

      :persistent_term.put({Cucumber, :after_suite_registered}, true)
    end
  end

  defp generate_module_name(file_path) do
    # Convert path like "test/features/authentication.feature"
    # to Test.Features.AuthenticationTest
    file_path
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

    {background_steps, scenario_steps} =
      Enum.split_with(pickle.steps, & &1.from_background)

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
      background_steps: Enum.map(background_steps, & &1.step),
      steps: Enum.map(scenario_steps, & &1.step),
      # Pickle step ids parallel to the step lists — testCase.testSteps
      # references them when the message sink is enabled
      background_step_ids: Enum.map(background_steps, & &1.id),
      step_ids: Enum.map(scenario_steps, & &1.id),
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
