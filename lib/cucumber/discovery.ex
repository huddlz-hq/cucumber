defmodule Cucumber.Discovery do
  @moduledoc """
  Discovers and loads feature files, step definitions, and hook modules.

  The discovery algorithm proceeds in this order:

  1. **Support files** are loaded first (default: `test/features/support/**/*.exs`),
     following the same convention as Ruby Cucumber. These typically define hooks.
  2. **Step definitions** are loaded next (default: `test/features/step_definitions/**/*.exs`).
     Each module using `Cucumber.StepDefinition` is registered.
  3. A **step registry** is built from all loaded step modules, mapping patterns to
     their implementing module and metadata. Duplicate patterns raise immediately.
  4. **Feature files** are parsed (default: `test/features/**/*.feature`) using
     `Gherkin.Parser` and annotated with their source file path.

  All default paths can be overridden via application config or opts passed to `discover/1`.
  """

  @default_features_pattern "test/features/**/*.feature"
  @default_steps_pattern "test/features/step_definitions/**/*.exs"
  @default_support_pattern "test/features/support/**/*.exs"

  defmodule DiscoveryResult do
    @moduledoc false
    defstruct features: [], step_modules: [], step_registry: %{}, hook_modules: []

    @type t :: %__MODULE__{
            features: [Gherkin.Feature.t()],
            step_modules: [module()],
            step_registry: %{String.t() => {module(), map()}},
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

    # Load support files first (like Ruby cucumber)
    hook_modules = load_support_files(support_patterns)

    # Discover and load step definitions
    step_modules = load_step_definitions(steps_patterns)

    # Build step registry from loaded modules
    step_registry = build_step_registry(step_modules)

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
        :features -> [@default_features_pattern]
        :steps -> [@default_steps_pattern]
        :support -> [@default_support_pattern]
      end
    end
  end

  defp load_support_files(patterns) do
    patterns
    |> expand_patterns()
    |> Enum.map(&load_hook_module/1)
    |> Enum.filter(& &1)
  end

  defp load_hook_module(path) do
    # Load the file and get the modules
    # Code.require_file returns nil if already loaded
    case Code.require_file(path) do
      nil ->
        nil

      modules ->
        modules
        |> Enum.map(fn {module, _} -> module end)
        |> Enum.find(fn module ->
          function_exported?(module, :__cucumber_hooks__, 0)
        end)
    end
  end

  defp load_step_definitions(patterns) do
    patterns
    |> expand_patterns()
    |> Enum.map(&load_step_module/1)
    |> Enum.filter(& &1)
  end

  defp load_step_module(path) do
    # Load the file and get the module
    modules = Code.require_file(path)

    # Find the step definition module(s)
    modules
    |> Enum.map(fn {module, _} -> module end)
    |> Enum.find(fn module ->
      function_exported?(module, :__cucumber_steps__, 0)
    end)
  end

  defp build_step_registry(modules) do
    Enum.reduce(modules, %{}, fn module, acc ->
      steps = module.__cucumber_steps__()
      add_module_steps_to_registry(acc, module, steps)
    end)
  end

  defp add_module_steps_to_registry(registry, module, steps) do
    Enum.reduce(steps, registry, fn {pattern, metadata}, acc ->
      # Check for duplicates using pattern as key
      if Map.has_key?(acc, pattern) do
        {existing_module, existing_meta} = acc[pattern]

        raise """
        Duplicate step definition: '#{pattern}'

        First defined in:
          #{existing_module} at #{existing_meta.file}:#{existing_meta.line}

        Also defined in:
          #{module} at #{metadata.file}:#{metadata.line}
        """
      end

      # Store with pattern as key (compile at runtime)
      Map.put(acc, pattern, {module, metadata})
    end)
  end

  defp discover_features(patterns) do
    patterns
    |> expand_patterns()
    |> Enum.map(&parse_feature/1)
    |> Enum.filter(& &1)
  end

  defp parse_feature(path) do
    content = File.read!(path)
    feature = Gherkin.Parser.parse(content)
    Map.put(feature, :file, path)
  end

  defp expand_patterns(patterns) do
    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
