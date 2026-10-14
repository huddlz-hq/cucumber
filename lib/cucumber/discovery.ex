defmodule Cucumber.Discovery do
  @moduledoc false

  # Discovers and loads feature files, step definitions, and hook modules.
  #
  # The discovery algorithm proceeds in this order:
  #
  # 1. **Support files** are loaded first (default: `test/features/support/**/*.exs`),
  #    following the same convention as Ruby Cucumber. These typically define hooks.
  # 2. **Step definitions** are loaded next (default: `test/features/step_definitions/**/*.exs`).
  #    Each module using `Cucumber.StepDefinition` is registered.
  # 3. A `Cucumber.StepRegistry` is built from the loaded step modules and
  #    parameter type modules.
  # 4. **Feature files** are parsed (default: `test/features/**/*.feature`
  #    plus `test/features/**/*.feature.md`) using `Gherkin.Parser` and
  #    annotated with their source file path. `.feature.md` files parse as
  #    Markdown with Gherkin (see `Gherkin.Markdown`).
  #
  # All default paths can be overridden via application config or opts passed to `discover/1`.

  @default_features_patterns ["test/features/**/*.feature", "test/features/**/*.feature.md"]
  @default_steps_pattern "test/features/step_definitions/**/*.exs"
  @default_support_pattern "test/features/support/**/*.exs"

  defmodule DiscoveryResult do
    @moduledoc false
    defstruct features: [],
              step_modules: [],
              step_registry: nil,
              hook_modules: []

    @type t :: %__MODULE__{
            features: [Gherkin.Feature.t()],
            step_modules: [module()],
            step_registry: Cucumber.StepRegistry.t(),
            hook_modules: [module()]
          }
  end

  @doc """
  Discovers all features and steps based on configuration.
  Returns a struct containing parsed features and a registry of steps.
  """
  @spec discover(keyword()) :: DiscoveryResult.t()
  def discover(opts \\ []) do
    features_patterns = get_patterns(:features, opts)
    steps_patterns = get_patterns(:steps, opts)
    support_patterns = get_patterns(:support, opts)

    # Load support files first (like Ruby cucumber); they define hooks and
    # custom parameter types
    {hook_modules, parameter_type_modules} = load_support_files(support_patterns)

    # Discover and load step definitions
    step_modules = load_step_definitions(steps_patterns)

    step_registry = Cucumber.StepRegistry.new(step_modules, parameter_type_modules)

    # Discover and parse feature files
    features = discover_features(features_patterns)

    %DiscoveryResult{
      features: features,
      step_modules: step_modules,
      step_registry: step_registry,
      hook_modules: hook_modules
    }
  end

  defp get_patterns(type, opts) do
    # Check for custom config
    custom_patterns = opts[type] || Application.get_env(:cucumber, type)

    if custom_patterns do
      List.wrap(custom_patterns)
    else
      # Use defaults
      case type do
        :features -> @default_features_patterns
        :steps -> [@default_steps_pattern]
        :support -> [@default_support_pattern]
      end
    end
  end

  defp load_support_files(patterns) do
    modules =
      patterns
      |> expand_patterns()
      |> Enum.flat_map(&loaded_modules/1)

    hook_modules = Enum.filter(modules, &function_exported?(&1, :__cucumber_hooks__, 0))

    parameter_type_modules =
      Enum.filter(modules, &function_exported?(&1, :__cucumber_parameter_types__, 0))

    {hook_modules, parameter_type_modules}
  end

  # Code.require_file/1 returns nil when the file was already loaded in this
  # VM, so cache each file's modules on first load; otherwise a second
  # discovery pass would crash on step files and silently drop hooks and
  # parameter types. Keyed on the expanded path because require_file
  # dedupes on the expanded path, so two spellings of one file must share
  # a cache entry.
  defp loaded_modules(path) do
    cache_key = {__MODULE__, :modules, Path.expand(path)}

    case Code.require_file(path) do
      nil ->
        # nil with no cache entry means someone other than discovery loaded
        # the file, so its modules are unknowable here. (A concurrent
        # discovery pass racing this one would land here too — loudly,
        # rather than silently building an empty registry.)
        case :persistent_term.get(cache_key, :missing) do
          :missing ->
            raise "#{path} was already loaded before Cucumber discovery ran, " <>
                    "so its modules cannot be discovered (Code.require_file/1 " <>
                    "returns nil for already-loaded files). Remove the earlier " <>
                    "Code.require_file call and let Cucumber load step and " <>
                    "support files itself."

          modules ->
            modules
        end

      modules ->
        module_names = Enum.map(modules, fn {module, _} -> module end)
        :persistent_term.put(cache_key, module_names)
        module_names
    end
  end

  defp load_step_definitions(patterns) do
    patterns
    |> expand_patterns()
    |> Enum.map(&load_step_module/1)
    |> Enum.filter(& &1)
  end

  defp load_step_module(path) do
    path
    |> loaded_modules()
    |> Enum.find(&function_exported?(&1, :__cucumber_steps__, 0))
  end

  defp discover_features(patterns) do
    patterns
    |> expand_patterns()
    |> Enum.map(&parse_feature/1)
    |> Enum.filter(& &1)
  end

  defp parse_feature(path) do
    content = File.read!(path)
    feature = Gherkin.Parser.parse(content, path)

    # The raw text is kept for the `source` message (#28) — the parsed AST
    # cannot reproduce it.
    feature
    |> Map.put(:file, path)
    |> Map.put(:source, content)
  end

  defp expand_patterns(patterns) do
    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
