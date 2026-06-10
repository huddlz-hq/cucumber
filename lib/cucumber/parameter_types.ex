defmodule Cucumber.ParameterTypes do
  @moduledoc """
  Defines custom parameter types for use in cucumber expressions.

  Custom parameter types let step patterns use domain vocabulary like
  `{flight}` with automatic transformation into domain values. Define them in
  a support file (loaded before step definitions):

      # test/features/support/parameter_types.exs
      defmodule MyApp.ParameterTypes do
        use Cucumber.ParameterTypes

        parameter_type :flight,
          regexp: ~r/([A-Z]{3})-([A-Z]{3})/,
          transform: fn from, to -> %{from: from, to: to} end

        parameter_type :color, regexp: ~r/red|blue|green/
      end

  Then use them in step definitions like any built-in type:

      step "{flight} has been delayed", %{args: [flight]} do
        # flight is %{from: "LHR", to: "CDG"}
      end

  ## Options

    * `:regexp` (required) - the regex a value must match. It is matched
      against the step text at the parameter's position.
    * `:transform` (optional) - a function converting the matched text into
      a value. With no capture groups in the regexp, it receives the full
      match; with capture groups, it receives one argument per group (`nil`
      for unmatched optional groups). Without a transform, the parameter
      yields the full matched string.

  Names must consist of lowercase letters and underscores, and cannot shadow
  the built-in types (`string`, `int`, `float`, `word`, `atom`).
  """

  @builtin_types ~w(string int float word atom)

  defmacro __using__(_opts) do
    quote do
      import Cucumber.ParameterTypes, only: [parameter_type: 2]

      Module.register_attribute(__MODULE__, :cucumber_parameter_types, accumulate: true)

      @before_compile Cucumber.ParameterTypes
    end
  end

  @doc """
  Registers a custom parameter type. See the module documentation.
  """
  defmacro parameter_type(name, opts) do
    name = name |> validate_name!(__CALLER__) |> to_string()

    unless Keyword.keyword?(opts) and Keyword.has_key?(opts, :regexp) do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description: "parameter_type #{inspect(name)} requires a :regexp option"
    end

    fun_name = :"__cucumber_parameter_type_#{name}__"

    quote do
      @cucumber_parameter_types {unquote(name), unquote(fun_name)}

      @doc false
      def unquote(fun_name)() do
        %{
          name: unquote(name),
          regexp: unquote(opts[:regexp]),
          transform: unquote(opts[:transform])
        }
      end
    end
  end

  defmacro __before_compile__(env) do
    types = Module.get_attribute(env.module, :cucumber_parameter_types, [])

    names = for {name, _} <- types, do: name
    duplicates = Enum.uniq(names -- Enum.uniq(names))

    if duplicates != [] do
      raise CompileError,
        file: env.file,
        description:
          "parameter type(s) defined more than once in #{inspect(env.module)}: " <>
            Enum.join(duplicates, ", ")
    end

    quote do
      @doc false
      def __cucumber_parameter_types__ do
        for {name, fun_name} <- unquote(Macro.escape(types)), into: %{} do
          {name, apply(__MODULE__, fun_name, [])}
        end
      end
    end
  end

  defp validate_name!(name, caller) when is_atom(name) or is_binary(name) do
    string = to_string(name)

    cond do
      string in @builtin_types ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "parameter type #{inspect(string)} shadows a built-in type " <>
              "(#{Enum.join(@builtin_types, ", ")} are reserved)"

      not Regex.match?(~r/^[a-z_]+$/, string) ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "invalid parameter type name #{inspect(string)}: names must consist of " <>
              "lowercase letters and underscores"

      true ->
        name
    end
  end

  defp validate_name!(name, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "parameter type name must be an atom or string, got: #{inspect(name)}"
  end
end
