defmodule Cucumber.MessagesTest do
  use ExUnit.Case, async: true

  alias Cucumber.Messages

  defp compile(source) do
    source
    |> Gherkin.Parser.parse()
    |> Map.put(:file, "features/demo.feature")
    |> Gherkin.Pickles.compile()
  end

  describe "source/2" do
    test "wraps the raw feature text with the gherkin media type" do
      assert Messages.source("features/demo.feature", "Feature: x\n") == %{
               source: %{
                 uri: "features/demo.feature",
                 data: "Feature: x\n",
                 mediaType: "text/x.cucumber.gherkin+plain"
               }
             }
    end
  end

  describe "gherkin_document/2" do
    test "wraps the compiled feature node with uri and empty comments" do
      %{document: document} =
        compile("""
        Feature: doc
          Scenario: s
            Given a step
        """)

      envelope = Messages.gherkin_document("features/demo.feature", document)

      assert %{gherkinDocument: %{uri: "features/demo.feature", comments: []}} = envelope
      assert envelope.gherkinDocument.feature == document
    end
  end

  describe "pickle/1" do
    test "carries ids, location, tags, and typed steps" do
      %{document: document, pickles: [pickle]} =
        compile("""
        @smoke
        Feature: p
          Scenario: buying
            Given money
            When I buy a cuke
        """)

      assert %{pickle: message} = Messages.pickle(pickle)

      assert message.id == pickle.id
      assert message.uri == "features/demo.feature"
      assert message.name == "buying"
      assert message.language == "en"
      assert message.location == %{line: 3}
      assert message.astNodeIds == pickle.ast_node_ids

      [feature_tag_node] = document.tags
      assert message.tags == [%{name: "@smoke", astNodeId: feature_tag_node.id}]

      assert [
               %{text: "money", type: "Context"},
               %{text: "I buy a cuke", type: "Action"}
             ] = message.steps

      for step <- message.steps do
        refute Map.has_key?(step, :argument)
      end
    end

    test "docstrings and datatables become pickle step arguments" do
      %{pickles: [pickle]} =
        compile("""
        Feature: args
          Scenario: with arguments
            Given a note:
              \"\"\"json
              {"a": 1}
              \"\"\"
            And a table:
              | k | v |
              | a | 1 |
        """)

      [note, table] = Messages.pickle(pickle).pickle.steps

      assert note.argument == %{docString: %{content: ~s({"a": 1}), mediaType: "json"}}

      assert table.argument == %{
               dataTable: %{
                 rows: [
                   %{cells: [%{value: "k"}, %{value: "v"}]},
                   %{cells: [%{value: "a"}, %{value: "1"}]}
                 ]
               }
             }
    end
  end

  describe "encode!/1" do
    test "produces one line of valid JSON with camelCase keys" do
      %{document: document, pickles: [pickle]} =
        compile("""
        Feature: ndjson
          Scenario: s
            Given a step
        """)

      lines = [
        Messages.source("features/demo.feature", "Feature: ndjson\n"),
        Messages.gherkin_document("features/demo.feature", document),
        Messages.pickle(pickle)
      ]

      for envelope <- lines do
        encoded = Messages.encode!(envelope)
        refute encoded =~ "\n"
        assert {:ok, decoded} = JSON.decode(encoded)
        assert map_size(decoded) == 1
      end

      decoded = JSON.decode!(Messages.encode!(Messages.pickle(pickle)))
      assert %{"pickle" => %{"astNodeIds" => [_], "steps" => [step]}} = decoded
      assert %{"id" => _, "text" => "a step", "type" => "Context", "astNodeIds" => [_]} = step
    end
  end
end
