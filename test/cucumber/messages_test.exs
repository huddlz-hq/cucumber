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

  describe "meta/0" do
    test "describes the implementation, runtime, os, and cpu" do
      assert %{meta: meta} = Messages.meta()

      assert meta.protocolVersion =~ ~r/^\d+\.\d+\.\d+$/
      assert meta.implementation.name == "cucumber-elixir"
      assert meta.implementation.version =~ ~r/^\d+\.\d+\.\d+/
      assert meta.runtime == %{name: "Elixir", version: System.version()}
      assert is_binary(meta.os.name)
      assert is_binary(meta.cpu.name)
    end
  end

  describe "step_definition/3" do
    test "cucumber expressions carry their pattern source and type" do
      reference = %{uri: "test/steps.exs", location: %{line: 7}}

      assert Messages.step_definition("9", {:expression, "I have {int} cukes"}, reference) == %{
               stepDefinition: %{
                 id: "9",
                 pattern: %{source: "I have {int} cukes", type: "CUCUMBER_EXPRESSION"},
                 sourceReference: reference
               }
             }
    end

    test "regexes carry their source and the regular-expression type" do
      envelope = Messages.step_definition("3", {:regex, {"^exactly (\\d+)$", ""}}, %{})

      assert envelope.stepDefinition.pattern == %{
               source: "^exactly (\\d+)$",
               type: "REGULAR_EXPRESSION"
             }
    end
  end

  describe "parameter_type/2" do
    test "carries the name and regex source" do
      definition = %{name: "flight", regexp: ~r/([A-Z]{3})-([A-Z]{3})/, transform: nil}

      assert Messages.parameter_type("4", definition) == %{
               parameterType: %{
                 id: "4",
                 name: "flight",
                 regularExpressions: ["([A-Z]{3})-([A-Z]{3})"],
                 preferForRegularExpressionMatch: false,
                 useForSnippets: true
               }
             }
    end
  end

  describe "hook/5" do
    test "maps hook kinds to schema hook types" do
      mapping = %{
        before_all: "BEFORE_TEST_RUN",
        after_all: "AFTER_TEST_RUN",
        before_scenario: "BEFORE_TEST_CASE",
        after_scenario: "AFTER_TEST_CASE",
        before_step: "BEFORE_TEST_STEP",
        after_step: "AFTER_TEST_STEP"
      }

      for {kind, type} <- mapping do
        assert %{hook: %{type: ^type}} = Messages.hook("1", kind, nil, nil, %{})
      end
    end

    test "includes tag expression and name only when present" do
      bare = Messages.hook("1", :before_scenario, nil, nil, %{uri: "hooks.exs"}).hook
      refute Map.has_key?(bare, :name)
      refute Map.has_key?(bare, :tagExpression)

      full = Messages.hook("2", :before_scenario, "@db", "prepare db", %{}).hook
      assert full.name == "prepare db"
      assert full.tagExpression == "@db"
    end
  end

  describe "run and test case envelopes" do
    test "testRunStarted and testRunFinished reference each other" do
      ts = Messages.timestamp(0)

      assert Messages.test_run_started("0", ts) == %{testRunStarted: %{id: "0", timestamp: ts}}

      assert Messages.test_run_finished(false, ts, "0") == %{
               testRunFinished: %{success: false, timestamp: ts, testRunStartedId: "0"}
             }
    end

    test "testRunHook envelopes bracket a run-level hook" do
      ts = Messages.timestamp(0)
      result = Messages.test_step_result(:passed, 5)

      assert Messages.test_run_hook_started("7", "0", "3", ts) == %{
               testRunHookStarted: %{id: "7", testRunStartedId: "0", hookId: "3", timestamp: ts}
             }

      assert Messages.test_run_hook_finished("7", result, ts) == %{
               testRunHookFinished: %{testRunHookStartedId: "7", result: result, timestamp: ts}
             }
    end

    test "testCase binds a pickle to hook and pickle test steps" do
      steps = [
        %{id: "10", hookId: "2"},
        %{id: "11", pickleStepId: "5", stepDefinitionIds: ["8"]}
      ]

      assert Messages.test_case("9", "6", steps, "0") == %{
               testCase: %{id: "9", pickleId: "6", testSteps: steps, testRunStartedId: "0"}
             }
    end

    test "testCaseStarted carries the 0-based attempt" do
      ts = Messages.timestamp(0)

      assert Messages.test_case_started("12", "9", 1, ts) == %{
               testCaseStarted: %{id: "12", testCaseId: "9", attempt: 1, timestamp: ts}
             }
    end

    test "testCaseFinished carries willBeRetried" do
      ts = Messages.timestamp(0)

      assert %{testCaseFinished: %{willBeRetried: true}} =
               Messages.test_case_finished("12", ts, true)
    end
  end

  describe "test_step_result/3" do
    test "maps statuses to the schema enum" do
      statuses = %{
        passed: "PASSED",
        failed: "FAILED",
        pending: "PENDING",
        skipped: "SKIPPED",
        undefined: "UNDEFINED",
        ambiguous: "AMBIGUOUS",
        unknown: "UNKNOWN"
      }

      for {status, string} <- statuses do
        assert %{status: ^string} = Messages.test_step_result(status, 0)
      end
    end

    test "includes the message only when present and clamps duration at zero" do
      refute Map.has_key?(Messages.test_step_result(:passed, 100), :message)

      result = Messages.test_step_result(:failed, -5, "boom")
      assert result.message == "boom"
      assert result.duration == %{seconds: 0, nanos: 0}
    end
  end

  describe "attachment/2" do
    test "identity attachments carry the body and step reference" do
      attachment = %Cucumber.Attachment{
        body: "hello",
        media_type: "text/plain",
        encoding: :identity,
        filename: "note.txt"
      }

      ref = %{test_case_started_id: "12", test_step_id: "13"}

      assert Messages.attachment(attachment, ref) == %{
               attachment: %{
                 body: "hello",
                 mediaType: "text/plain",
                 contentEncoding: "IDENTITY",
                 fileName: "note.txt",
                 testCaseStartedId: "12",
                 testStepId: "13"
               }
             }
    end

    test "base64 attachments without a reference omit the optional fields" do
      attachment = %Cucumber.Attachment{
        body: Base.encode64(<<1, 2, 3>>),
        media_type: "image/png",
        encoding: :base64
      }

      assert %{attachment: payload} = Messages.attachment(attachment, nil)
      assert payload.contentEncoding == "BASE64"
      refute Map.has_key?(payload, :fileName)
      refute Map.has_key?(payload, :testCaseStartedId)
      refute Map.has_key?(payload, :testStepId)
    end
  end

  describe "timestamp/1 and duration/1" do
    test "split nanoseconds into seconds and nanos" do
      assert Messages.timestamp(1_500_000_001) == %{seconds: 1, nanos: 500_000_001}
      assert Messages.timestamp(0) == %{seconds: 0, nanos: 0}
      assert Messages.duration(2_000_000_003) == %{seconds: 2, nanos: 3}
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
