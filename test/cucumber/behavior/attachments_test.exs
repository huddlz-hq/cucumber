defmodule Cucumber.AttachmentsTest do
  @moduledoc """
  Behavior tests for the attachments API (#25), driven by the vendored CCK
  `attachments` sample plus inline features for hook attribution and
  async isolation.

  Until Cucumber Messages land (#28), attachments are recorded in the
  `Cucumber.RunCoordinator` (exposed by the harness as `run.attachments`)
  and surface in step-failure output.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.Attachment

  defmodule Steps do
    use Cucumber.StepDefinition

    # 0..9 are all valid UTF-8 bytes, which is exactly why binary data must
    # be marked explicitly with {:bytes, ...} rather than sniffed
    @ten_bytes :binary.list_to_bin(Enum.to_list(0..9))
    @fake_pdf <<"%PDF-1.4", 0, 255, 254, "fake">>

    step "the string {string} is attached as {string}", %{args: [text, media_type]} = context do
      Cucumber.attach(context, text, media_type)
    end

    step "the string {string} is logged", %{args: [text]} = context do
      Cucumber.log(context, text)
    end

    step "text with ANSI escapes is logged", context do
      Cucumber.log(
        context,
        "This displays a \e[31mr\e[0m\e[91ma\e[0m\e[33mi\e[0m\e[32mn\e[0m\e[34mb\e[0m\e[95mo\e[0m\e[35mw\e[0m"
      )
    end

    step "the following string is attached as {string}:", %{args: [media_type]} = context do
      Cucumber.attach(context, context.docstring, media_type)
    end

    step "an array with {int} bytes is attached as {string}",
         %{args: [size, media_type]} = context do
      data = :binary.list_to_bin(Enum.to_list(0..(size - 1)))
      Cucumber.attach(context, {:bytes, data}, media_type)
    end

    step "a PDF document is attached and renamed", context do
      Cucumber.attach(context, {:bytes, @fake_pdf}, "application/pdf", filename: "renamed.pdf")
    end

    step "a link to {string} is attached", %{args: [uri]} = context do
      Cucumber.link(context, uri)
    end

    step "the string {string} is attached as {string} before a failure",
         %{args: [text, media_type]} = context do
      Cucumber.attach(context, text, media_type)
      raise "whoops"
    end

    def ten_bytes, do: @ten_bytes
  end

  describe "the CCK attachments sample" do
    test "every attachment records equivalently to the reference" do
      source = File.read!("test/fixtures/cck/attachments/attachments.feature")
      run = run_feature(source, steps: [Steps], file: "attachments.feature")

      # Only the deliberate failure at the end fails
      assert %{total: 8, failures: 1, passed: 7} = run

      # One attachment per scenario, in scenario order (the feature is not
      # @async, so execution order within the module is the seed order —
      # match by content, not position)
      assert length(run.attachments) == 8

      by_scenario = Map.new(run.attachments, &{&1.scenario_name, &1})

      # Strings attach as-is with their media type
      assert %Attachment{
               body: "hello",
               media_type: "application/octet-stream",
               encoding: :identity,
               filename: nil
             } = by_scenario["Strings can be attached with a media type"]

      # log uses the reference implementations' log media type
      assert %Attachment{body: "hello", media_type: "text/x.cucumber.log+plain"} =
               by_scenario["Log text"]

      assert %Attachment{media_type: "text/x.cucumber.log+plain", body: "This displays a " <> _} =
               by_scenario["Log ANSI coloured text"]

      # Docstring content attaches verbatim
      assert %Attachment{
               body: ~s({"message": "The <b>big</b> question", "foo": "bar"}),
               media_type: "application/json"
             } = by_scenario["Log JSON"]

      # Byte arrays are base64-encoded regardless of media type
      bytes = by_scenario["Byte arrays are base64-encoded regardless of media type"]
      assert %Attachment{media_type: "text/plain", encoding: :base64} = bytes
      assert Base.decode64!(bytes.body) == Steps.ten_bytes()

      # Filenames are carried along
      assert %Attachment{filename: "renamed.pdf", media_type: "application/pdf"} =
               by_scenario["Attaching PDFs with a different filename"]

      # link uses text/uri-list
      assert %Attachment{body: "https://cucumber.io", media_type: "text/uri-list"} =
               by_scenario["Attaching URIs"]

      # An attachment recorded right before the step fails is retained...
      failing = by_scenario["Attaching during a failed step"]
      assert %Attachment{body: "hello", media_type: "application/octet-stream"} = failing

      # ...and surfaces in the failure output
      assert run.output =~ "Attachments:"
      assert run.output =~ "* application/octet-stream: hello"
    end
  end

  describe "attribution" do
    test "attachments record the step that attached them" do
      run =
        run_feature(
          """
          Feature: step attribution
            Scenario: attaches twice
              Given the string "first" is attached as "text/plain"
              And the string "second" is attached as "text/plain"
          """,
          steps: [Steps],
          file: "attribution.feature"
        )

      assert %{failures: 0, passed: 1} = run

      assert [
               %Attachment{
                 body: "first",
                 phase: :step,
                 step_text: "the string \"first\" is attached as \"text/plain\"",
                 feature_file: "attribution.feature",
                 scenario_name: "attaches twice"
               },
               %Attachment{body: "second", step_line: 3}
             ] = run.attachments
    end

    test "attachments from scenario hooks attribute to the hook phase" do
      defmodule AttachingHooks do
        use Cucumber.Hooks

        before_scenario context do
          Cucumber.log(context, "from before hook")
          {:ok, context}
        end

        after_scenario context do
          Cucumber.log(context, "from after hook")
          :ok
        end
      end

      run =
        run_feature(
          """
          Feature: hook attribution
            Scenario: hooks attach
              Given the string "mid" is attached as "text/plain"
          """,
          steps: [Steps],
          hooks: [AttachingHooks]
        )

      assert %{failures: 0, passed: 1} = run

      assert [
               %Attachment{body: "from before hook", phase: :before_scenario, step_text: nil},
               %Attachment{body: "mid", phase: :step},
               %Attachment{body: "from after hook", phase: :after_scenario, step_text: nil}
             ] = run.attachments

      # Hook attachments still belong to their scenario
      assert Enum.all?(run.attachments, &(&1.scenario_name == "hooks attach"))
    end

    test "attachments from step hooks attribute to the bracketed step" do
      defmodule AttachingStepHooks do
        use Cucumber.Hooks

        after_step context do
          Cucumber.log(context, "step finished: #{context.step_status}")
          :ok
        end
      end

      run =
        run_feature(
          """
          Feature: step hook attribution
            Scenario: traced
              Given the string "payload" is attached as "text/plain"
          """,
          steps: [Steps],
          hooks: [AttachingStepHooks]
        )

      assert %{failures: 0, passed: 1} = run

      assert [
               %Attachment{body: "payload", phase: :step},
               %Attachment{
                 body: "step finished: passed",
                 phase: :step,
                 step_text: "the string \"payload\" is attached as \"text/plain\""
               }
             ] = run.attachments
    end

    test "concurrent async scenarios don't cross-contaminate" do
      run =
        run_feature(
          """
          @async
          Feature: concurrent attachments
            Scenario: alpha
              Given the string "alpha" is attached as "text/plain"

            Scenario: beta
              Given the string "beta" is attached as "text/plain"

            Scenario: gamma
              Given the string "gamma" is attached as "text/plain"
          """,
          steps: [Steps]
        )

      assert %{total: 3, failures: 0, passed: 3} = run
      assert length(run.attachments) == 3

      # Every attachment is attributed to the scenario whose step recorded
      # it — the body and scenario name always agree
      assert Enum.all?(run.attachments, &(&1.body == &1.scenario_name))
    end
  end

  describe "composability" do
    test "attach returns the context unchanged so any return style works" do
      defmodule ComposingSteps do
        use Cucumber.StepDefinition

        step "I attach and update the context", context do
          context
          |> Cucumber.attach("note", "text/plain")
          |> Map.put(:updated, true)
        end

        step "the context update survived", context do
          if context.updated, do: :ok, else: {:error, "context lost"}
        end
      end

      run =
        run_feature(
          """
          Feature: composing
            Scenario: attach mid-pipeline
              Given I attach and update the context
              Then the context update survived
          """,
          steps: [ComposingSteps]
        )

      assert %{failures: 0, passed: 1} = run
      assert [%Attachment{body: "note"}] = run.attachments
    end
  end
end
