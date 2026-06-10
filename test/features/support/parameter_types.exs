defmodule FeatureParameterTypes do
  use Cucumber.ParameterTypes

  parameter_type(:iata_route,
    regexp: ~r/([A-Z]{3})-([A-Z]{3})/,
    transform: fn from, to -> %{from: from, to: to} end
  )

  parameter_type(:priority, regexp: ~r/low|normal|high/)
end
