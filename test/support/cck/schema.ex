defmodule Cucumber.CckSchema do
  @moduledoc """
  Offline validator for the JSON Schema vocabulary used by Messages 33.0.2.

  Reads the unmodified upstream bundle. This is intentionally not a general
  JSON Schema implementation: unknown validation keywords fail closed.
  """
  import ExUnit.Assertions

  @path "test/fixtures/messages/messages.schema.json"
  @external_resource @path
  @schema @path |> File.read!() |> JSON.decode!()
  @annotations ~w($schema $id $defs definitions description deprecated)
  @constraints ~w($ref type properties additionalProperties required items enum minimum maximum minItems)

  def assert_valid(envelope) do
    assert is_map(envelope) and map_size(envelope) == 1,
           "envelope must contain exactly one message"

    validate(envelope, @schema, @schema, "envelope")
  end

  defp validate(value, schema, document, path) do
    assert Map.keys(schema) -- (@annotations ++ @constraints) == [],
           "unsupported schema keywords at #{path}"

    case schema do
      %{"$ref" => ref} ->
        {target, document} = resolve(ref, document)
        validate(value, target, document, path)

      _ ->
        assert type?(value, schema["type"]), "#{path}: expected #{schema["type"]}"
        constraints(value, schema, document, path)
    end
  end

  defp resolve("#/" <> pointer, document) do
    {get_in(document, String.split(pointer, "/")), document}
  end

  defp resolve(ref, _document) do
    document = Map.fetch!(@schema["$defs"], "https://cucumber.io/schema/" <> Path.basename(ref))
    {document, document}
  end

  defp constraints(value, schema, document, path) do
    if schema["enum"], do: assert(value in schema["enum"], "#{path}: invalid enum value")

    if Map.has_key?(schema, "minimum"),
      do: assert(value >= schema["minimum"], "#{path}: below minimum")

    if Map.has_key?(schema, "maximum"),
      do: assert(value <= schema["maximum"], "#{path}: above maximum")

    children(value, schema, document, path)
  end

  defp children(value, %{"type" => "object"} = schema, document, path) do
    properties = Map.get(schema, "properties", %{})

    for key <- Map.get(schema, "required", []) do
      assert Map.has_key?(value, key), "#{path}: missing required #{key}"
    end

    if schema["additionalProperties"] == false do
      assert Map.keys(value) -- Map.keys(properties) == [], "#{path}: unknown properties"
    end

    for {key, child} <- value, Map.has_key?(properties, key) do
      validate(child, properties[key], document, path <> "." <> key)
    end
  end

  defp children(value, %{"type" => "array"} = schema, document, path) do
    assert length(value) >= Map.get(schema, "minItems", 0), "#{path}: too few items"

    for {child, index} <- Enum.with_index(value) do
      validate(child, schema["items"], document, "#{path}[#{index}]")
    end
  end

  defp children(_value, _schema, _document, _path), do: :ok

  defp type?(v, "object"), do: is_map(v)
  defp type?(v, "array"), do: is_list(v)
  defp type?(v, "string"), do: is_binary(v)
  defp type?(v, "integer"), do: is_integer(v)
  defp type?(v, "number"), do: is_number(v)
  defp type?(v, "boolean"), do: is_boolean(v)
  defp type?(_v, nil), do: true
end
