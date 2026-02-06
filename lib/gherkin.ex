defmodule Gherkin.Feature do
  @moduledoc """
  Represents a parsed Gherkin feature file (minimal subset).

  A Feature is the top-level element in a Gherkin file, containing a name,
  optional description, optional background, and one or more scenarios.
  It can also have tags that apply to all scenarios in the feature.
  """
  defstruct name: "", description: "", background: nil, scenarios: [], tags: []

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          background: Gherkin.Background.t() | nil,
          scenarios: [Gherkin.Scenario.t() | Gherkin.ScenarioOutline.t()],
          tags: [String.t()]
        }
end

defmodule Gherkin.Background do
  @moduledoc """
  Represents a Gherkin Background section.

  A Background contains steps that are run before each scenario in the feature.
  It allows you to define common setup steps that apply to all scenarios.
  """
  defstruct steps: []

  @type t :: %__MODULE__{
          steps: [Gherkin.Step.t()]
        }
end

defmodule Gherkin.Scenario do
  @moduledoc """
  Represents a Gherkin Scenario section.

  A Scenario is a concrete example that illustrates a business rule.
  It consists of a name, a list of steps, optional tags for filtering,
  and the line number where it appears in the source file.
  """
  defstruct name: "", steps: [], tags: [], line: nil

  @type t :: %__MODULE__{
          name: String.t(),
          steps: [Gherkin.Step.t()],
          tags: [String.t()],
          line: non_neg_integer() | nil
        }
end

defmodule Gherkin.ScenarioOutline do
  @moduledoc """
  Represents a Gherkin Scenario Outline section.

  A Scenario Outline is a template that runs multiple times with different data
  from Examples tables. Placeholders in step text use `<name>` syntax and are
  substituted with values from each row of the Examples table.
  """
  defstruct name: "", steps: [], tags: [], examples: [], line: nil

  @type t :: %__MODULE__{
          name: String.t(),
          steps: [Gherkin.Step.t()],
          tags: [String.t()],
          examples: [Gherkin.Examples.t()],
          line: non_neg_integer() | nil
        }
end

defmodule Gherkin.Examples do
  @moduledoc """
  Represents an Examples block within a Scenario Outline.

  Each Examples block contains a table of data used to parameterize the outline.
  The first row contains headers (placeholder names), and subsequent rows contain
  values to substitute. Examples blocks can have optional names and tags.
  """
  defstruct name: "", tags: [], table_header: [], table_body: [], line: nil

  @type t :: %__MODULE__{
          name: String.t(),
          tags: [String.t()],
          table_header: [String.t()],
          table_body: [[String.t()]],
          line: non_neg_integer() | nil
        }
end

defmodule Gherkin.Step do
  @moduledoc """
  Represents a Gherkin step (Given/When/Then/And/But/*).

  A Step is a single action or assertion in a scenario. It consists of:
  - keyword: The step type (Given, When, Then, And, But, or *)
  - text: The step text that matches step definitions
  - docstring: Optional multi-line text block (triple-quoted)
  - datatable: Optional table data (pipe-delimited)
  - line: Line number in the source file
  """
  defstruct keyword: "", text: "", docstring: nil, datatable: nil, line: nil

  @type t :: %__MODULE__{
          keyword: String.t(),
          text: String.t(),
          docstring: String.t() | nil,
          datatable: [[String.t()]] | nil,
          line: non_neg_integer() | nil
        }
end

defmodule Gherkin.Parser do
  @moduledoc """
  Gherkin parser using NimbleParsec.

  This module parses Gherkin feature files into Elixir structs, supporting:
  - Feature with name, description, and tags
  - Background with steps
  - Scenarios with steps and tags
  - Scenario Outlines with Examples
  - Steps with keywords, text, docstrings, and datatables

  It implements a subset of the Gherkin language focused on core BDD concepts.
  """

  @doc """
  Parses a Gherkin feature file from a string into structured data.

  This function takes a string containing Gherkin syntax and parses it into a
  structured `Gherkin.Feature` struct with its associated components.

  ## Parameters

  * `gherkin_string` - A string containing Gherkin syntax

  ## Returns

  Returns a `%Gherkin.Feature{}` struct containing:
  * `name` - The feature name
  * `description` - The feature description
  * `tags` - List of feature-level tags
  * `background` - Background steps (if present)
  * `scenarios` - List of scenarios

  ## Examples

      # Parse a string containing Gherkin syntax
      Gherkin.Parser.parse("Feature: Shopping Cart\\nScenario: Adding an item")
      # Returns %Gherkin.Feature{} struct with parsed data
  """
  @spec parse(String.t()) :: Gherkin.Feature.t()
  defdelegate parse(gherkin_string), to: Gherkin.NimbleParser
end
