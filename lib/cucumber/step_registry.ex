defmodule Cucumber.StepRegistry do
  @moduledoc """
  The complete set of step definitions and parameter types for a run, and
  the one place step text is matched against them.

  A registry is built once from step definition modules (see
  `Cucumber.StepDefinition`) and parameter type modules (see
  `Cucumber.ParameterTypes`). Building it:

    * merges the parameter types, raising if two modules register the same
      name
    * compiles every pattern once, so matching never compiles
    * raises on a step definition registered twice (identical expressions,
      or identical regexes with identical flags)
    * drops, with a warning, any definition whose expression references an
      undefined parameter type — mirroring reference Cucumber, steps that
      would have matched it are reported as undefined
    * orders definitions by file and line, so `definitions/1` is stable
      across runs

  ## Examples

      registry = Cucumber.StepRegistry.new([MyApp.Steps], [MyApp.ParameterTypes])

      case Cucumber.StepRegistry.match(registry, "I have 3 cukes") do
        {:ok, definition, args} -> {definition.module, definition.function, args}
        :undefined -> :undefined
        {:ambiguous, matches} -> Enum.map(matches, fn {definition, _args} -> definition end)
      end
  """

  alias Cucumber.Expression

  defmodule Definition do
    @moduledoc """
    One step definition in a `Cucumber.StepRegistry`.

      * `:position` - the definition's index in file-and-line order
      * `:kind` - `:expression` (cucumber expression) or `:regex`
      * `:source` - the expression text, or the regex source
      * `:module` / `:function` - the step function, called with the context
      * `:file` / `:line` - where the definition is written

    The `:matcher` field is internal.
    """

    @enforce_keys [:position, :kind, :source, :module, :function, :file, :line, :matcher]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            position: non_neg_integer(),
            kind: :expression | :regex,
            source: String.t(),
            module: module(),
            function: atom(),
            file: String.t(),
            line: pos_integer(),
            matcher: term()
          }

    @doc """
    Renders the pattern as written: an expression verbatim, a regex as a
    sigil with its flags.

    ## Examples

        Cucumber.StepRegistry.Definition.display_pattern(definition)
        # => "I have {int} cukes" or "~r/^I have (\\d+) cukes$/i"
    """
    @spec display_pattern(t()) :: String.t()
    def display_pattern(%__MODULE__{kind: :expression, source: source}), do: source

    def display_pattern(%__MODULE__{kind: :regex, matcher: {:regex, regex, _, _}}),
      do: inspect(regex)
  end

  @enforce_keys [:definitions, :parameter_types]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            definitions: [Definition.t()],
            parameter_types: Expression.custom_types()
          }

  @type match_result ::
          {:ok, Definition.t(), [term()]}
          | :undefined
          | {:ambiguous, [{Definition.t(), [term()]}]}

  @doc """
  Builds a registry from step definition modules and parameter type modules.

  Raises on duplicate step definitions or duplicate parameter types; see the
  module documentation for everything building checks.

  ## Examples

      Cucumber.StepRegistry.new([MyApp.Steps])
      Cucumber.StepRegistry.new([MyApp.Steps], [MyApp.ParameterTypes])
  """
  @spec new([module()], [module()]) :: t()
  def new(step_modules, parameter_type_modules \\ []) do
    parameter_types = merge_parameter_types(parameter_type_modules)

    definitions =
      step_modules
      |> Enum.flat_map(fn module ->
        for {pattern, metadata} <- module.__cucumber_steps__(), do: {pattern, module, metadata}
      end)
      |> Enum.flat_map(&build_definition(&1, parameter_types))
      |> reject_duplicates!()
      |> Enum.sort_by(&{&1.file, &1.line})
      |> Enum.with_index(fn definition, position -> %{definition | position: position} end)

    %__MODULE__{definitions: definitions, parameter_types: parameter_types}
  end

  @doc """
  Matches step text against every definition.

  Returns `{:ok, definition, args}` for exactly one match, `:undefined` for
  none, and `{:ambiguous, matches}` — every match, in definition order — for
  more than one. Expression args are converted by their parameter types;
  regex args are the captured strings, `nil` for unmatched optional groups.

  ## Examples

      Cucumber.StepRegistry.match(registry, "I have 3 cukes")
      # => {:ok, %Cucumber.StepRegistry.Definition{source: "I have {int} cukes"}, [3]}
  """
  @spec match(t(), String.t()) :: match_result()
  def match(%__MODULE__{definitions: definitions}, step_text) do
    matches =
      for definition <- definitions,
          {:match, args} <- [run_matcher(definition.matcher, step_text)],
          do: {definition, args}

    case matches do
      [] -> :undefined
      [{definition, args}] -> {:ok, definition, args}
      many -> {:ambiguous, many}
    end
  end

  @doc """
  Returns every definition, ordered by file and line.

  ## Examples

      Cucumber.StepRegistry.definitions(registry)
      # => [%Cucumber.StepRegistry.Definition{position: 0, ...}, ...]
  """
  @spec definitions(t()) :: [Definition.t()]
  def definitions(%__MODULE__{definitions: definitions}), do: definitions

  @doc """
  Returns the parameter types the registry was built with, keyed by name.

  ## Examples

      Cucumber.StepRegistry.parameter_types(registry)
      # => %{"color" => %{name: "color", regexp: ~r/red|blue/, transform: nil}}
  """
  @spec parameter_types(t()) :: Expression.custom_types()
  def parameter_types(%__MODULE__{parameter_types: parameter_types}), do: parameter_types

  # -- building ---------------------------------------------------------------

  defp merge_parameter_types(modules) do
    for module <- modules,
        {name, definition} <- module.__cucumber_parameter_types__(),
        reduce: %{} do
      acc ->
        if Map.has_key?(acc, name) do
          raise """
          Parameter type {#{name}} is defined in more than one module
          (#{inspect(module)} among them). Each custom parameter type may
          only be registered once.
          """
        end

        Map.put(acc, name, definition)
    end
  end

  # Identical regexes don't compile to structurally-equal structs, so they
  # are compared by source and flags.
  defp reject_duplicates!(definitions) do
    definitions
    |> Enum.group_by(&duplicate_key/1)
    |> Enum.find_value(fn
      {_key, [existing, duplicate | _]} -> {existing, duplicate}
      _ -> nil
    end)
    |> case do
      nil -> definitions
      {existing, duplicate} -> raise_duplicate!(existing, duplicate)
    end
  end

  defp raise_duplicate!(existing, duplicate) do
    raise """
    Duplicate step definition: '#{Definition.display_pattern(duplicate)}'

    First defined in:
      #{existing.module} at #{existing.file}:#{existing.line}

    Also defined in:
      #{duplicate.module} at #{duplicate.file}:#{duplicate.line}
    """
  end

  defp duplicate_key(%Definition{kind: :regex, matcher: {:regex, regex, _, _}}),
    do: {:regex, Regex.source(regex), Regex.opts(regex)}

  defp duplicate_key(%Definition{kind: :expression, source: source}), do: {:expression, source}

  defp build_definition({pattern, module, metadata}, parameter_types) do
    case compile_matcher(pattern, parameter_types) do
      {:ok, kind, source, matcher} ->
        [
          %Definition{
            position: nil,
            kind: kind,
            source: source,
            module: module,
            function: metadata.function,
            file: metadata.file,
            line: metadata.line,
            matcher: matcher
          }
        ]

      {:error, {:undefined_parameter_type, type}} ->
        IO.warn(
          "Cucumber: step definition \"#{pattern}\" " <>
            "(#{metadata.file}:#{metadata.line}) references undefined parameter " <>
            "type {#{type}} and will be ignored. Steps matching it will " <>
            "be reported as undefined.",
          []
        )

        []
    end
  end

  # Cucumber regexes must match the entire step text: author-supplied ^/$
  # anchors still work inside the non-capturing group. The capture list is
  # explicit because PCRE silently drops *trailing* unmatched groups.
  defp compile_matcher(%Regex{} = regex, _parameter_types) do
    source = Regex.source(regex)
    anchored = Regex.compile!("\\A(?:#{source})\\z", Regex.opts(regex))
    group_count = Expression.count_capture_groups(source)
    capture = if group_count == 0, do: [0], else: Enum.to_list(1..group_count)

    {:ok, :regex, source, {:regex, regex, anchored, capture}}
  end

  defp compile_matcher(expression, parameter_types) do
    with {:ok, compiled} <- Expression.compile_checked(expression, parameter_types) do
      {:ok, :expression, expression, {:expression, compiled}}
    end
  end

  # -- matching ---------------------------------------------------------------

  defp run_matcher({:expression, compiled}, step_text), do: Expression.match(step_text, compiled)

  defp run_matcher({:regex, _regex, anchored, capture}, step_text) do
    case :re.run(step_text, anchored.re_pattern, [{:capture, capture, :index}]) do
      :nomatch -> :no_match
      {:match, _indexes} when capture == [0] -> {:match, []}
      {:match, indexes} -> {:match, Enum.map(indexes, &group_value(&1, step_text))}
    end
  end

  defp group_value({-1, 0}, _step_text), do: nil
  defp group_value({start, length}, step_text), do: binary_part(step_text, start, length)
end
