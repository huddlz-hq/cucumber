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
    @moduledoc "Result struct returned by `Cucumber.Discovery.discover/1`."
    defstruct features: [],
              step_modules: [],
              step_registry: %{},
              hook_modules: [],
              parameter_types: %{}

    @typedoc """
    Registry keys identify the pattern kind and pattern — `{:expression, source}`
    for cucumber expressions, `{:regex, {source, opts}}` for regular
    expressions. Regexes are keyed by source and options rather than the
    `%Regex{}` struct because identical regexes do not compile to
    structurally-equal `re_pattern` binaries.
    """
    @type registry_key :: {:expression, String.t()} | {:regex, {String.t(), term()}}

    @type t :: %__MODULE__{
            features: [Gherkin.Feature.t()],
            step_modules: [module()],
            step_registry: %{registry_key() => {module(), map()}},
            hook_modules: [module()],
            parameter_types: Cucumber.Expression.custom_types()
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
    parameter_types = build_parameter_types(parameter_type_modules)

    # Discover and load step definitions
    step_modules = load_step_definitions(steps_patterns)

    # Build step registry from loaded modules
    step_registry = build_step_registry(step_modules, parameter_types)

    # Discover and parse feature files
    features = discover_features(features_patterns)

    %DiscoveryResult{
      features: features,
      step_modules: step_modules,
      step_registry: step_registry,
      hook_modules: hook_modules,
      parameter_types: parameter_types
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
    modules =
      patterns
      |> expand_patterns()
      |> Enum.flat_map(&load_support_modules/1)

    hook_modules = Enum.filter(modules, &function_exported?(&1, :__cucumber_hooks__, 0))

    parameter_type_modules =
      Enum.filter(modules, &function_exported?(&1, :__cucumber_parameter_types__, 0))

    {hook_modules, parameter_type_modules}
  end

  defp load_support_modules(path) do
    # Code.require_file returns nil if already loaded
    case Code.require_file(path) do
      nil -> []
      modules -> Enum.map(modules, fn {module, _} -> module end)
    end
  end

  defp build_parameter_types(modules) do
    all_types =
      for module <- modules,
          {name, definition} <- module.__cucumber_parameter_types__(),
          do: {name, module, definition}

    Enum.reduce(all_types, %{}, &add_parameter_type/2)
  end

  defp add_parameter_type({name, module, definition}, acc) do
    if Map.has_key?(acc, name) do
      raise """
      Parameter type {#{name}} is defined in more than one module
      (#{inspect(module)} among them). Each custom parameter type may
      only be registered once.
      """
    end

    Map.put(acc, name, definition)
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

  defp build_step_registry(modules, parameter_types) do
    Enum.reduce(modules, %{}, fn module, acc ->
      steps = module.__cucumber_steps__()
      add_module_steps_to_registry(acc, module, steps, parameter_types)
    end)
  end

  @doc false
  # Shared key derivation so every registry builder (discovery, test
  # harnesses) produces the same shape. Identical regexes (same source and
  # flags) produce equal keys, so duplicate detection covers them too.
  @spec registry_key(String.t() | Regex.t()) :: DiscoveryResult.registry_key()
  def registry_key(%Regex{} = regex), do: {:regex, {Regex.source(regex), Regex.opts(regex)}}
  def registry_key(pattern) when is_binary(pattern), do: {:expression, pattern}

  defp add_module_steps_to_registry(registry, module, steps, parameter_types) do
    Enum.reduce(steps, registry, fn {pattern, metadata}, acc ->
      key = registry_key(pattern)

      cond do
        not compilable_pattern?(pattern, metadata, parameter_types) ->
          # Mirrors reference Cucumber: a definition with an undefined
          # parameter type is excluded (with a warning) rather than aborting
          # the run; steps that would have used it fail as undefined.
          acc

        Map.has_key?(acc, key) ->
          duplicate_definition!(acc[key], pattern, module, metadata)

        true ->
          Map.put(acc, key, {module, metadata})
      end
    end)
  end

  @doc false
  # Public so test harnesses building registries directly apply the same
  # undefined-parameter-type semantics as discovery.
  def compilable_pattern?(%Regex{}, _metadata, _parameter_types), do: true

  def compilable_pattern?(pattern, metadata, parameter_types) do
    # Eagerly compile (also warming the cache) so undefined parameter types
    # surface at load time rather than mid-scenario.
    Cucumber.Expression.compile(pattern, parameter_types)
    true
  rescue
    e in Cucumber.UndefinedParameterTypeError ->
      IO.warn(
        "Cucumber: step definition \"#{pattern}\" " <>
          "(#{metadata.file}:#{metadata.line}) references undefined parameter " <>
          "type {#{e.type_name}} and will be ignored. Steps matching it will " <>
          "be reported as undefined.",
        []
      )

      false
  end

  defp duplicate_definition!({existing_module, existing_meta}, pattern, module, metadata) do
    raise """
    Duplicate step definition: '#{display_pattern(pattern)}'

    First defined in:
      #{existing_module} at #{existing_meta.file}:#{existing_meta.line}

    Also defined in:
      #{module} at #{metadata.file}:#{metadata.line}
    """
  end

  defp display_pattern(%Regex{} = regex), do: inspect(regex)
  defp display_pattern(pattern), do: pattern

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
