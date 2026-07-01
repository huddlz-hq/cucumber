defmodule Cucumber.Messages do
  @moduledoc """
  Builders and NDJSON encoding for [Cucumber Messages](https://github.com/cucumber/messages),
  the protocol every Cucumber implementation emits so formatters, report
  services, and the Cucumber Compatibility Kit can consume runs uniformly.

  A message is an *envelope*: a single-key map whose key names the message
  type (mirroring the schema's `oneof`) and whose value is the payload,
  with camelCase keys matching the JSON schema. One envelope per line,
  JSON-encoded, makes the NDJSON stream.

  This module covers the *static* messages — those derivable from source
  files alone:

    * `source/2` - the raw feature file text
    * `gherkin_document/2` - the parsed AST (built by `Gherkin.Pickles`)
    * `pickle/1` - a compiled `Gherkin.Pickle`

  Run-time messages (`testCase`, `testCaseStarted`, results, attachments)
  are emitted by the runner (#28b).

  ## Example

      compilation = Gherkin.Pickles.compile(feature)

      [
        Cucumber.Messages.source(feature.file, source_text),
        Cucumber.Messages.gherkin_document(feature.file, compilation.document)
        | Enum.map(compilation.pickles, &Cucumber.Messages.pickle/1)
      ]
      |> Enum.map_join("\\n", &Cucumber.Messages.encode!/1)
  """

  @gherkin_media_type "text/x.cucumber.gherkin+plain"

  @typedoc "A single-key envelope map, e.g. `%{pickle: %{...}}`."
  @type envelope :: %{required(atom()) => map()}

  @doc """
  Builds a `source` envelope carrying a feature file's raw text.
  """
  @spec source(String.t(), String.t()) :: envelope()
  def source(uri, data) do
    %{source: %{uri: uri, data: data, mediaType: @gherkin_media_type}}
  end

  @doc """
  Builds a `gherkinDocument` envelope from a compiled feature node.

  `feature_node` is the `document` produced by `Gherkin.Pickles.compile/2`.
  The parser discards comments, so `comments` is always empty.
  """
  @spec gherkin_document(String.t(), map()) :: envelope()
  def gherkin_document(uri, feature_node) do
    %{gherkinDocument: %{uri: uri, feature: feature_node, comments: []}}
  end

  @doc """
  Builds a `pickle` envelope from a `Gherkin.Pickle`.
  """
  @spec pickle(Gherkin.Pickle.t()) :: envelope()
  def pickle(%Gherkin.Pickle{} = pickle) do
    %{
      pickle: %{
        id: pickle.id,
        uri: pickle.uri,
        name: pickle.name,
        language: pickle.language,
        location: Gherkin.Pickles.location(pickle.line),
        astNodeIds: pickle.ast_node_ids,
        tags: Enum.map(pickle.tags, &%{name: &1.name, astNodeId: &1.ast_node_id}),
        steps: Enum.map(pickle.steps, &pickle_step/1)
      }
    }
  end

  @doc """
  Encodes an envelope as one NDJSON line (no trailing newline).
  """
  @spec encode!(envelope()) :: String.t()
  def encode!(envelope) when is_map(envelope) do
    JSON.encode!(envelope)
  end

  defp pickle_step(%Gherkin.PickleStep{} = pickle_step) do
    base = %{
      id: pickle_step.id,
      text: pickle_step.text,
      type: pickle_step_type(pickle_step.type),
      astNodeIds: pickle_step.ast_node_ids
    }

    case pickle_step_argument(pickle_step.step) do
      nil -> base
      argument -> Map.put(base, :argument, argument)
    end
  end

  defp pickle_step_type(:context), do: "Context"
  defp pickle_step_type(:action), do: "Action"
  defp pickle_step_type(:outcome), do: "Outcome"
  defp pickle_step_type(:unknown), do: "Unknown"

  # Pickle step arguments carry content only — no ids or locations
  # (those live in the gherkinDocument nodes the astNodeIds point to).
  defp pickle_step_argument(%{docstring: docstring} = step) when is_binary(docstring) do
    doc_string =
      case step.docstring_media_type do
        nil -> %{content: docstring}
        media_type -> %{content: docstring, mediaType: media_type}
      end

    %{docString: doc_string}
  end

  defp pickle_step_argument(%{datatable: [_ | _] = datatable}) do
    rows =
      Enum.map(datatable, fn row ->
        %{cells: Enum.map(row, &%{value: &1})}
      end)

    %{dataTable: %{rows: rows}}
  end

  defp pickle_step_argument(_step), do: nil
end
