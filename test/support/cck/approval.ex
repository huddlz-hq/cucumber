defmodule Cucumber.CckApproval do
  @moduledoc """
  Normalized comparison of Cucumber Messages streams against the Cucumber
  Compatibility Kit's reference NDJSON.

  The CCK ships a reference `.ndjson` for every sample, produced by
  `fake-cucumber` (Node.js). An implementation conforms when its own message
  stream is *equivalent* — same envelopes, in the same order, with consistent
  internal references — even though ids, timings, and platform details
  necessarily differ. `assert_equivalent/3` normalizes both streams with the
  same rules and asserts they are identical.

  ## Normalization rules

  Dropped envelopes:

    * `meta` — implementation/platform description, different by design
    * `suggestion` — snippet suggestions for undefined steps; this
      implementation reports suggestions in the step error instead of the
      message stream
    * `undefinedParameterType` — this implementation raises
      `Cucumber.UndefinedParameterTypeError` at discovery instead of
      emitting a stream (see the filtered samples list)

  Dropped fields (wherever they occur):

    * `timestamp`, `duration` — wall-clock values
    * `sourceReference` — step definitions and hooks live in `.exs`
      modules, not the reference's TypeScript files
    * `stepMatchArgumentsLists` — not emitted (documented delta in
      `Cucumber.Messages`)
    * `message`, `exception` — failure text is implementation-specific
      (Elixir exceptions vs. JavaScript stack traces)
    * `column` — the Gherkin parser tracks lines, not columns

  Rewritten fields:

    * `uri` — reduced to the file's basename (`samples/minimal/...` vs.
      `test/fixtures/cck/minimal/...`)
    * `description` — whitespace-normalized per line (indentation handling
      differs between parsers)

  Structural normalization:

    * `stepDefinition`/`hook`/`parameterType` envelopes are emitted in
      source order by the reference but in a canonical order by this
      implementation; both streams get the block sorted by content.
    * `testCase` envelopes are hoisted to immediately after
      `testRunStarted`, preserving their relative order: the reference
      emits every test case up front, this implementation emits each one
      as its scenario starts. Both orders satisfy the protocol (a
      `testCase` must precede its `testCaseStarted`).
    * All ids are renumbered sequentially in order of first definition,
      and every `*Id`/`*Ids` reference is remapped. A reference to an id
      that was never defined fails the assertion — so referential
      consistency is checked *before* ids stop being comparable.

  ## Options

    * `:drop` — extra envelope types to drop for a specific sample; each
      use must be justified in the approval test's samples table
    * `:drop_feature_description` — drop `gherkinDocument.feature.description`
      (that field only; descriptions elsewhere stay compared); for the
      `markdown` sample, whose reference description is a tokenizer quirk
    * `:drop_step_definition_patterns` — drop `stepDefinition.pattern`;
      for samples that rely on duplicate identical step definitions,
      which this implementation rejects at discovery (the equivalent
      ambiguity is produced with two distinct overlapping patterns)
  """

  import ExUnit.Assertions

  @dropped_envelopes ~w(meta suggestion undefinedParameterType)
  @definition_envelopes ~w(stepDefinition hook parameterType)
  @dropped_keys ~w(timestamp duration sourceReference stepMatchArgumentsLists message exception column)

  @doc """
  Asserts that two message streams are equivalent after normalization.

  `actual` and `reference` are lists of decoded envelope maps. On mismatch,
  fails with the first differing envelope pair (or the two envelope-type
  sequences when the streams have different shapes).
  """
  def assert_equivalent(actual, reference, opts \\ []) do
    actual = normalize(actual, opts)
    reference = normalize(reference, opts)

    actual_types = Enum.map(actual, &envelope_type/1)
    reference_types = Enum.map(reference, &envelope_type/1)

    if actual_types != reference_types do
      flunk("""
      envelope sequences differ

      actual:    #{inspect(actual_types)}
      reference: #{inspect(reference_types)}
      """)
    end

    [actual, reference, Stream.iterate(0, &(&1 + 1))]
    |> Enum.zip()
    |> Enum.each(fn {a, r, index} ->
      if a != r do
        flunk("""
        envelope #{index} (#{envelope_type(a)}) differs

        actual:    #{inspect(a, pretty: true, limit: :infinity)}

        reference: #{inspect(r, pretty: true, limit: :infinity)}
        """)
      end
    end)
  end

  @doc """
  Normalizes a decoded envelope stream per the module documentation.
  """
  def normalize(envelopes, opts \\ []) do
    dropped = @dropped_envelopes ++ Keyword.get(opts, :drop, [])

    envelopes
    |> Enum.reject(&(envelope_type(&1) in dropped))
    |> Enum.map(&scrub(&1, opts))
    |> sort_definitions()
    |> hoist_test_cases()
    |> canonicalize_ids()
  end

  defp envelope_type(envelope), do: envelope |> Map.keys() |> List.first()

  # -- field scrubbing --------------------------------------------------

  defp scrub(%{"stepDefinition" => definition} = envelope, opts) do
    definition =
      if opts[:drop_step_definition_patterns],
        do: Map.delete(definition, "pattern"),
        else: definition

    scrub_node(%{envelope | "stepDefinition" => definition})
  end

  defp scrub(%{"gherkinDocument" => %{"feature" => feature} = document} = envelope, opts) do
    feature =
      if opts[:drop_feature_description],
        do: Map.delete(feature, "description"),
        else: feature

    scrub_node(%{envelope | "gherkinDocument" => %{document | "feature" => feature}})
  end

  defp scrub(envelope, _opts), do: scrub_node(envelope)

  defp scrub_node(map) when is_map(map) do
    map
    |> Map.drop(@dropped_keys)
    |> Map.new(fn
      {"uri", uri} -> {"uri", Path.basename(uri)}
      {"description", text} -> {"description", squish(text)}
      {key, value} -> {key, scrub_node(value)}
    end)
  end

  defp scrub_node(list) when is_list(list), do: Enum.map(list, &scrub_node/1)
  defp scrub_node(value), do: value

  defp squish(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map_join("\n", &String.trim/1)
    |> String.trim()
  end

  # -- definition-block ordering ----------------------------------------

  # Step definition, hook, and parameterType envelopes all precede
  # testRunStarted in both streams, but their relative order is emitter
  # policy. Pull them out and re-insert them sorted (by their content,
  # ids excluded) immediately before testRunStarted.
  defp sort_definitions(envelopes) do
    {definitions, rest} =
      Enum.split_with(envelopes, &(envelope_type(&1) in @definition_envelopes))

    definitions = Enum.sort_by(definitions, &sort_key/1)

    case Enum.split_while(rest, &(envelope_type(&1) != "testRunStarted")) do
      {statics, [] = _no_run} -> statics ++ definitions
      {statics, run} -> statics ++ definitions ++ run
    end
  end

  defp sort_key(envelope), do: envelope |> drop_ids() |> JSON.encode!()

  # The reference emits every testCase directly after testRunStarted; this
  # implementation emits each one as its scenario starts. Hoist them (in
  # order) to the reference's position in both streams.
  defp hoist_test_cases(envelopes) do
    {test_cases, rest} = Enum.split_with(envelopes, &(envelope_type(&1) == "testCase"))

    case Enum.split_while(rest, &(envelope_type(&1) != "testRunStarted")) do
      {before_run, [run_started | after_run]} ->
        before_run ++ [run_started] ++ test_cases ++ after_run

      {_all, []} ->
        envelopes
    end
  end

  defp drop_ids(map) when is_map(map) do
    map
    |> Map.reject(fn {key, _} -> id_key?(key) end)
    |> Map.new(fn {key, value} -> {key, drop_ids(value)} end)
  end

  defp drop_ids(list) when is_list(list), do: Enum.map(list, &drop_ids/1)
  defp drop_ids(value), do: value

  defp id_key?(key),
    do: key == "id" or String.ends_with?(key, "Id") or String.ends_with?(key, "Ids")

  # -- id canonicalization ----------------------------------------------

  defp canonicalize_ids(envelopes) do
    {envelopes, _mapping} = Enum.map_reduce(envelopes, %{}, &canon_node/2)
    envelopes
  end

  defp canon_node(map, mapping) when is_map(map) do
    # Assign a canonical id to this node's own "id" before resolving any
    # references in sibling or child fields.
    {map, mapping} =
      case map do
        %{"id" => id} ->
          canonical = Integer.to_string(map_size(mapping))
          {%{map | "id" => canonical}, Map.put(mapping, id, canonical)}

        _ ->
          {map, mapping}
      end

    map
    |> Enum.sort()
    |> Enum.map_reduce(mapping, fn
      {"id", value}, mapping ->
        {{"id", value}, mapping}

      {key, value}, mapping ->
        cond do
          String.ends_with?(key, "Ids") ->
            {{key, Enum.map(value, &resolve(&1, mapping, key))}, mapping}

          String.ends_with?(key, "Id") ->
            {{key, resolve(value, mapping, key)}, mapping}

          true ->
            canon_entry(key, value, mapping)
        end
    end)
    |> then(fn {entries, mapping} -> {Map.new(entries), mapping} end)
  end

  defp canon_node(list, mapping) when is_list(list),
    do: Enum.map_reduce(list, mapping, &canon_node/2)

  defp canon_node(value, mapping), do: {value, mapping}

  defp canon_entry(key, value, mapping) do
    {value, mapping} = canon_node(value, mapping)
    {{key, value}, mapping}
  end

  defp resolve(id, mapping, key) do
    case mapping do
      %{^id => canonical} ->
        canonical

      _ ->
        flunk("referential consistency violation: #{key} references undefined id #{inspect(id)}")
    end
  end
end
