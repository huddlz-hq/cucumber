defmodule Cucumber.Messages do
  @moduledoc """
  Builders and NDJSON encoding for [Cucumber Messages](https://github.com/cucumber/messages),
  the protocol every Cucumber implementation emits so formatters, report
  services, and the Cucumber Compatibility Kit can consume runs uniformly.

  A message is an *envelope*: a single-key map whose key names the message
  type (mirroring the schema's `oneof`) and whose value is the payload,
  with camelCase keys matching the JSON schema. One envelope per line,
  JSON-encoded, makes the NDJSON stream.

  Two groups of builders live here:

    * **Static messages** — derivable from source files alone: `meta/0`,
      `source/2`, `gherkin_document/2`, `pickle/1`, `step_definition/3`,
      `parameter_type/2`, and `hook/5`.
    * **Run-time messages** — describing an execution: `test_run_started/2`,
      `test_case/4`, `test_case_started/4`, `test_step_started/3`,
      `test_step_finished/4`, `test_case_finished/3`, `attachment/2`,
      `test_run_hook_started/4`, `test_run_hook_finished/3`, and
      `test_run_finished/3`.

  These builders are pure — id allocation, ordering, and NDJSON output are
  owned by `Cucumber.RunCoordinator` (the run-wide message sink) and driven
  by `Cucumber.Messages.Emitter`. Enable the stream with

      config :cucumber, messages: "cucumber-messages.ndjson"

  ## Example

  Ids must be unique across the whole stream, so when emitting several
  features, thread `next_id` from one compilation into the next (as
  `Cucumber.Compiler.compile_features!/1` does):

      {lines, _next_id} =
        Enum.flat_map_reduce(features, 0, fn feature, start_id ->
          compilation = Gherkin.Pickles.compile(feature, start_id)

          envelopes = [
            Cucumber.Messages.source(feature.file, feature.source),
            Cucumber.Messages.gherkin_document(feature.file, compilation.document)
            | Enum.map(compilation.pickles, &Cucumber.Messages.pickle/1)
          ]

          {Enum.map(envelopes, &Cucumber.Messages.encode!/1), compilation.next_id}
        end)

  ## Known deltas from the reference stream

  `testCase.testSteps` entries do not carry `stepMatchArgumentsLists`
  (expression matching returns converted values, not source offsets), and
  `parameterType`/`hook` envelopes have no source line (their macros don't
  record one). The CCK approval harness (#28c) normalizes these.
  """

  @gherkin_media_type "text/x.cucumber.gherkin+plain"

  # The cucumber/messages schema major version these envelope shapes track.
  # #28c vendors the schema files and pins this against them.
  @protocol_version "27.0.0"

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

  @typedoc "A step/hook result status accepted by `test_step_result/3`."
  @type status :: :passed | :failed | :pending | :skipped | :undefined | :ambiguous | :unknown

  @typedoc "A `%{seconds: integer, nanos: integer}` map (timestamp or duration)."
  @type instant :: %{seconds: integer(), nanos: integer()}

  @doc """
  Builds the `meta` envelope describing this implementation and its host.
  """
  @spec meta() :: envelope()
  def meta do
    {_family, os_name} = :os.type()

    %{
      meta: %{
        protocolVersion: @protocol_version,
        implementation: %{name: "cucumber-elixir", version: implementation_version()},
        runtime: %{name: "Elixir", version: System.version()},
        os: %{name: to_string(os_name)},
        cpu: %{name: cpu_name()}
      }
    }
  end

  @doc """
  Builds a `stepDefinition` envelope from a step-registry entry.

  `key` is a `Cucumber.Discovery` registry key; `source_reference` is a
  `%{uri: ..., location: %{line: ...}}` map.
  """
  @spec step_definition(String.t(), Cucumber.Discovery.DiscoveryResult.registry_key(), map()) ::
          envelope()
  def step_definition(id, {:expression, source}, source_reference) do
    step_definition_envelope(id, source, "CUCUMBER_EXPRESSION", source_reference)
  end

  def step_definition(id, {:regex, {source, _opts}}, source_reference) do
    step_definition_envelope(id, source, "REGULAR_EXPRESSION", source_reference)
  end

  defp step_definition_envelope(id, source, type, source_reference) do
    %{
      stepDefinition: %{
        id: id,
        pattern: %{source: source, type: type},
        sourceReference: source_reference
      }
    }
  end

  @doc """
  Builds a `parameterType` envelope from a custom parameter type definition
  (see `Cucumber.ParameterTypes`).
  """
  @spec parameter_type(String.t(), %{
          required(:name) => String.t(),
          required(:regexp) => Regex.t()
        }) ::
          envelope()
  def parameter_type(id, %{name: name, regexp: regexp}) do
    %{
      parameterType: %{
        id: id,
        name: name,
        regularExpressions: [Regex.source(regexp)],
        preferForRegularExpressionMatch: false,
        useForSnippets: true
      }
    }
  end

  @doc """
  Builds a `hook` envelope. `type` is a `Cucumber.Hooks` hook kind;
  `tag` and `name` may be nil.
  """
  @spec hook(String.t(), Cucumber.Hooks.hook_type(), String.t() | nil, String.t() | nil, map()) ::
          envelope()
  def hook(id, type, tag, name, source_reference) do
    payload =
      %{id: id, type: hook_type(type), sourceReference: source_reference}
      |> put_present(:name, name)
      |> put_present(:tagExpression, tag)

    %{hook: payload}
  end

  defp hook_type(:before_all), do: "BEFORE_TEST_RUN"
  defp hook_type(:after_all), do: "AFTER_TEST_RUN"
  defp hook_type(:before_scenario), do: "BEFORE_TEST_CASE"
  defp hook_type(:after_scenario), do: "AFTER_TEST_CASE"
  defp hook_type(:before_step), do: "BEFORE_TEST_STEP"
  defp hook_type(:after_step), do: "AFTER_TEST_STEP"

  @doc """
  Builds a `testRunStarted` envelope.
  """
  @spec test_run_started(String.t(), instant()) :: envelope()
  def test_run_started(id, timestamp) do
    %{testRunStarted: %{id: id, timestamp: timestamp}}
  end

  @doc """
  Builds a `testRunFinished` envelope. `success` is false when any scenario
  failed.
  """
  @spec test_run_finished(boolean(), instant(), String.t() | nil) :: envelope()
  def test_run_finished(success, timestamp, test_run_started_id) do
    payload =
      %{success: success, timestamp: timestamp}
      |> put_present(:testRunStartedId, test_run_started_id)

    %{testRunFinished: payload}
  end

  @doc """
  Builds a `testRunHookStarted` envelope (a `before_all`/`after_all` hook
  beginning execution).
  """
  @spec test_run_hook_started(String.t(), String.t() | nil, String.t() | nil, instant()) ::
          envelope()
  def test_run_hook_started(id, test_run_started_id, hook_id, timestamp) do
    payload =
      %{id: id, timestamp: timestamp}
      |> put_present(:testRunStartedId, test_run_started_id)
      |> put_present(:hookId, hook_id)

    %{testRunHookStarted: payload}
  end

  @doc """
  Builds a `testRunHookFinished` envelope.
  """
  @spec test_run_hook_finished(String.t(), map(), instant()) :: envelope()
  def test_run_hook_finished(test_run_hook_started_id, result, timestamp) do
    %{
      testRunHookFinished: %{
        testRunHookStartedId: test_run_hook_started_id,
        result: result,
        timestamp: timestamp
      }
    }
  end

  @doc """
  Builds a `testCase` envelope binding a pickle to its executable test steps.

  Each entry in `test_steps` is either a pickle step
  (`%{id: ..., pickleStepId: ..., stepDefinitionIds: [...]}`) or a
  scenario-hook step (`%{id: ..., hookId: ...}`), in execution order.
  """
  @spec test_case(String.t(), String.t(), [map()], String.t() | nil) :: envelope()
  def test_case(id, pickle_id, test_steps, test_run_started_id) do
    payload =
      %{id: id, pickleId: pickle_id, testSteps: test_steps}
      |> put_present(:testRunStartedId, test_run_started_id)

    %{testCase: payload}
  end

  @doc """
  Builds a `testCaseStarted` envelope. `attempt` is 0-based (retries
  increment it).
  """
  @spec test_case_started(String.t(), String.t(), non_neg_integer(), instant()) :: envelope()
  def test_case_started(id, test_case_id, attempt, timestamp) do
    %{
      testCaseStarted: %{id: id, testCaseId: test_case_id, attempt: attempt, timestamp: timestamp}
    }
  end

  @doc """
  Builds a `testStepStarted` envelope.
  """
  @spec test_step_started(String.t(), String.t(), instant()) :: envelope()
  def test_step_started(test_case_started_id, test_step_id, timestamp) do
    %{
      testStepStarted: %{
        testCaseStartedId: test_case_started_id,
        testStepId: test_step_id,
        timestamp: timestamp
      }
    }
  end

  @doc """
  Builds a `testStepFinished` envelope. Build `result` with
  `test_step_result/3`.
  """
  @spec test_step_finished(String.t(), String.t(), map(), instant()) :: envelope()
  def test_step_finished(test_case_started_id, test_step_id, result, timestamp) do
    %{
      testStepFinished: %{
        testCaseStartedId: test_case_started_id,
        testStepId: test_step_id,
        testStepResult: result,
        timestamp: timestamp
      }
    }
  end

  @doc """
  Builds a `TestStepResult` payload for `test_step_finished/4` (and
  `test_run_hook_finished/3`).
  """
  @spec test_step_result(status(), non_neg_integer(), String.t() | nil) :: map()
  def test_step_result(status, duration_ns, message \\ nil) do
    %{status: status_string(status), duration: duration(duration_ns)}
    |> put_present(:message, message)
  end

  @doc """
  Builds a `testCaseFinished` envelope. `will_be_retried` marks a failed
  attempt that a retry follows.
  """
  @spec test_case_finished(String.t(), instant(), boolean()) :: envelope()
  def test_case_finished(test_case_started_id, timestamp, will_be_retried) do
    %{
      testCaseFinished: %{
        testCaseStartedId: test_case_started_id,
        timestamp: timestamp,
        willBeRetried: will_be_retried
      }
    }
  end

  @doc """
  Builds an `attachment` envelope from a `Cucumber.Attachment`.

  `ref` carries `:test_case_started_id`/`:test_step_id` when the attachment
  was recorded during a step (both optional in the schema).
  """
  @spec attachment(Cucumber.Attachment.t(), map() | nil) :: envelope()
  def attachment(%Cucumber.Attachment{} = attachment, ref) do
    ref = ref || %{}

    payload =
      %{
        body: attachment.body,
        mediaType: attachment.media_type,
        contentEncoding: content_encoding(attachment.encoding)
      }
      |> put_present(:fileName, attachment.filename)
      |> put_present(:testCaseStartedId, ref[:test_case_started_id])
      |> put_present(:testStepId, ref[:test_step_id])

    %{attachment: payload}
  end

  defp content_encoding(:base64), do: "BASE64"
  defp content_encoding(:identity), do: "IDENTITY"

  @doc """
  Converts a `System.system_time(:nanosecond)` value into a message
  timestamp.
  """
  @spec timestamp(integer()) :: instant()
  def timestamp(nanoseconds) do
    %{seconds: div(nanoseconds, 1_000_000_000), nanos: rem(nanoseconds, 1_000_000_000)}
  end

  @doc """
  Converts a monotonic nanosecond difference into a message duration
  (clamped at zero).
  """
  @spec duration(integer()) :: instant()
  def duration(nanoseconds), do: timestamp(max(nanoseconds, 0))

  defp status_string(:passed), do: "PASSED"
  defp status_string(:failed), do: "FAILED"
  defp status_string(:pending), do: "PENDING"
  defp status_string(:skipped), do: "SKIPPED"
  defp status_string(:undefined), do: "UNDEFINED"
  defp status_string(:ambiguous), do: "AMBIGUOUS"
  defp status_string(:unknown), do: "UNKNOWN"

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp implementation_version do
    case Application.spec(:cucumber, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp cpu_name do
    :system_architecture
    |> :erlang.system_info()
    |> to_string()
    |> String.split("-")
    |> hd()
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
