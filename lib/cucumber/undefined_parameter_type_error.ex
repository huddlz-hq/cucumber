defmodule Cucumber.UndefinedParameterTypeError do
  @moduledoc """
  Raised when a step pattern references a parameter type that is neither a
  built-in nor a registered custom type (see `Cucumber.ParameterTypes`).

  During discovery, step definitions with undefined parameter types are
  excluded from the registry with a warning — steps that would have matched
  them fail as undefined, mirroring reference Cucumber implementations. This
  exception surfaces when such a pattern is compiled directly via
  `Cucumber.Expression.compile/2`.
  """

  defexception [:message, :type_name, :pattern]

  @type t :: %__MODULE__{
          message: String.t(),
          type_name: String.t(),
          pattern: String.t() | nil
        }

  @doc false
  @spec new(String.t(), String.t() | nil) :: t()
  def new(type_name, pattern \\ nil) do
    where = if pattern, do: ~s( in pattern "#{pattern}"), else: ""

    message = """
    Undefined parameter type {#{type_name}}#{where}.

    Register it in a support file:

        defmodule MyParameterTypes do
          use Cucumber.ParameterTypes

          parameter_type :#{type_name}, regexp: ~r/.../, transform: fn value -> value end
        end
    """

    %__MODULE__{message: message, type_name: type_name, pattern: pattern}
  end
end
