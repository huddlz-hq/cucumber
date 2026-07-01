defmodule Gherkin.Feature do
  @moduledoc """
  Represents a parsed Gherkin feature file (minimal subset).

  A Feature is the top-level element in a Gherkin file, containing a name,
  optional description, optional background, scenarios, and rules.
  It can also have tags that apply to all scenarios in the feature.
  """
  defstruct name: "",
            description: "",
            background: nil,
            scenarios: [],
            rules: [],
            tags: [],
            line: nil

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          background: Gherkin.Background.t() | nil,
          scenarios: [Gherkin.Scenario.t() | Gherkin.ScenarioOutline.t()],
          rules: [Gherkin.Rule.t()],
          tags: [String.t()],
          line: non_neg_integer() | nil
        }
end

defmodule Gherkin.Rule do
  @moduledoc """
  Represents a Gherkin Rule section.

  A Rule groups related scenarios under a feature to express a business rule.
  It can have its own description, tags, and Background; rule-background steps
  run after the feature-background steps for each scenario in the rule, and
  rule tags are inherited by those scenarios.
  """
  defstruct name: "", description: "", background: nil, scenarios: [], tags: [], line: nil

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          background: Gherkin.Background.t() | nil,
          scenarios: [Gherkin.Scenario.t() | Gherkin.ScenarioOutline.t()],
          tags: [String.t()],
          line: non_neg_integer() | nil
        }
end

defmodule Gherkin.Background do
  @moduledoc """
  Represents a Gherkin Background section.

  A Background contains steps that are run before each scenario in the feature.
  It allows you to define common setup steps that apply to all scenarios.
  """
  defstruct name: "", steps: [], description: "", line: nil

  @type t :: %__MODULE__{
          name: String.t(),
          steps: [Gherkin.Step.t()],
          description: String.t(),
          line: non_neg_integer() | nil
        }
end

defmodule Gherkin.Scenario do
  @moduledoc """
  Represents a Gherkin Scenario section.

  A Scenario is a concrete example that illustrates a business rule.
  It consists of a name, an optional free-form description, a list of steps,
  optional tags for filtering, and the line number where it appears in the
  source file. When a scenario was defined inside a `Rule`, `rule` carries
  the rule's name (set during compilation, not by the parser).
  """
  defstruct name: "",
            description: "",
            steps: [],
            tags: [],
            line: nil,
            rule: nil,
            keyword: "Scenario"

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          steps: [Gherkin.Step.t()],
          tags: [String.t()],
          line: non_neg_integer() | nil,
          rule: String.t() | nil,
          keyword: String.t()
        }
end

defmodule Gherkin.ScenarioOutline do
  @moduledoc """
  Represents a Gherkin Scenario Outline section.

  A Scenario Outline is a template that runs multiple times with different data
  from Examples tables. Placeholders in step text use `<name>` syntax and are
  substituted with values from each row of the Examples table.
  """
  defstruct name: "",
            description: "",
            steps: [],
            tags: [],
            examples: [],
            line: nil,
            keyword: "Scenario Outline"

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          steps: [Gherkin.Step.t()],
          tags: [String.t()],
          examples: [Gherkin.Examples.t()],
          line: non_neg_integer() | nil,
          keyword: String.t()
        }
end

defmodule Gherkin.Examples do
  @moduledoc """
  Represents an Examples block within a Scenario Outline.

  Each Examples block contains a table of data used to parameterize the outline.
  The first row contains headers (placeholder names), and subsequent rows contain
  values to substitute. Examples blocks can have optional names, descriptions,
  and tags.
  """
  defstruct name: "",
            description: "",
            tags: [],
            table_header: [],
            table_body: [],
            line: nil,
            keyword: "Examples",
            table_header_line: nil,
            table_body_lines: nil

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          tags: [String.t()],
          table_header: [String.t()],
          table_body: [[String.t()]],
          line: non_neg_integer() | nil,
          keyword: String.t(),
          table_header_line: non_neg_integer() | nil,
          table_body_lines: [non_neg_integer()] | nil
        }
end

defmodule Gherkin.Step do
  @moduledoc """
  Represents a Gherkin step (Given/When/Then/And/But/*).

  A Step is a single action or assertion in a scenario. It consists of:
  - keyword: The step type (Given, When, Then, And, But, or *)
  - text: The step text that matches step definitions
  - docstring: Optional multi-line text block (delimited by `\"\"\"` or triple backticks)
  - docstring_media_type: Optional media type annotation on the opening
    docstring delimiter (e.g. `json` in `\"\"\"json`)
  - datatable: Optional table data (pipe-delimited)
  - line: Line number in the source file

  `docstring_line` and `datatable_lines` record the source lines of the
  docstring's opening delimiter and of each datatable row (parallel to
  `datatable`) for Cucumber Messages locations; the published `docstring`
  and `datatable` shapes are unchanged.
  """
  defstruct keyword: "",
            text: "",
            docstring: nil,
            docstring_media_type: nil,
            datatable: nil,
            line: nil,
            docstring_line: nil,
            datatable_lines: nil

  @type t :: %__MODULE__{
          keyword: String.t(),
          text: String.t(),
          docstring: String.t() | nil,
          docstring_media_type: String.t() | nil,
          datatable: [[String.t()]] | nil,
          line: non_neg_integer() | nil,
          docstring_line: non_neg_integer() | nil,
          datatable_lines: [non_neg_integer()] | nil
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
