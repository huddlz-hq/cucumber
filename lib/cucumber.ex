defmodule Cucumber do
  @moduledoc """
  A behavior-driven development (BDD) testing framework for Elixir using Gherkin syntax.

  Cucumber is a testing framework that allows you to write executable specifications
  in natural language. It bridges the gap between technical and non-technical stakeholders
  by allowing tests to be written in plain language while being executed as code.

  ## Setup

  Add to your `test_helper.exs`:

      Cucumber.compile_features!()

  ## File Structure

  By default, Cucumber expects the following structure:

      test/
        features/
          authentication.feature
          shopping.feature
          step_definitions/
            authentication_steps.exs
            shopping_steps.exs
            common_steps.exs
          support/
            hooks.exs

  ## Configuration

  You can customize paths in `config/test.exs`:

      config :cucumber,
        features: ["test/features/**/*.feature"],
        steps: ["test/features/step_definitions/**/*.exs"]

  Setting `messages: "cucumber-messages.ndjson"` additionally writes a
  [Cucumber Messages](https://github.com/cucumber/messages) NDJSON stream
  describing the run — see `Cucumber.Messages`.

  ## Step Definitions

  Create step definition modules using `Cucumber.StepDefinition`:

      defmodule AuthenticationSteps do
        use Cucumber.StepDefinition

        step "I am logged in as {string}", %{args: [username]} = context do
          {:ok, Map.put(context, :current_user, username)}
        end
      end

  ## Running Tests

  Cucumber tests run with `mix test` and can be filtered using tags:

      # Run all tests including Cucumber
      mix test

      # Run only Cucumber tests
      mix test --only cucumber

      # Exclude Cucumber tests
      mix test --exclude cucumber

  ## Key Features

  * Auto-discovery of features and step definitions
  * Integration with ExUnit's tagging system
  * Context passing between steps
  * Support for data tables and doc strings
  * Rich error reporting with suggestions
  """

  @doc """
  Discovers and compiles all cucumber features into ExUnit tests.

  This function should be called in your `test_helper.exs` file.

  ## Options

    * `:features` - List of patterns for feature files
    * `:steps` - List of patterns for step definition files
    * `:support` - List of patterns for support files

  ## Examples

      # Use default paths
      Cucumber.compile_features!()

      # Use custom paths
      Cucumber.compile_features!(
        features: ["test/acceptance/**/*.feature"],
        steps: ["test/acceptance/steps/**/*.exs"]
      )
  """
  @spec compile_features!(keyword()) :: [module()]
  def compile_features!(opts \\ []) do
    modules = Cucumber.Compiler.compile_features!(opts)

    # Return the compiled module names for debugging
    modules
  end

  @doc """
  Attaches data to the current step (or hook execution) for reporting.

  Mirrors the `attach` API of reference Cucumber implementations: useful
  for capturing screenshots, response payloads, or logs while a scenario
  runs. Attachments are recorded against the step that attached them; until
  a step fails they are invisible, then they are listed in the failure
  output. (Cucumber Messages formatters will render them in reports, #28.)

  `data` is either a string (attached as-is) or `{:bytes, binary}` for
  binary data, which is Base64-encoded — Elixir can't tell text from bytes
  by type, so binary data is marked explicitly.

  Returns the context unchanged, so it composes with any step return style.

  ## Options

    * `:filename` - a file name for the attachment (e.g. `"screenshot.png"`)

  ## Examples

      step "I take a screenshot", context do
        Cucumber.attach(context, {:bytes, screenshot()}, "image/png",
          filename: "checkout.png"
        )
      end

      step "the API responds", context do
        context
        |> Cucumber.attach(response.body, "application/json")
        |> Map.put(:response, response)
      end
  """
  @spec attach(map(), String.t() | {:bytes, binary()}, String.t(), keyword()) :: map()
  def attach(context, data, media_type, opts \\ [])

  def attach(context, {:bytes, binary}, media_type, opts) when is_binary(binary) do
    record_attachment(context, Base.encode64(binary), media_type, :base64, opts)
  end

  def attach(context, text, media_type, opts) when is_binary(text) do
    record_attachment(context, text, media_type, :identity, opts)
  end

  @doc """
  Attaches a log message to the current step.

  Convenience for `attach(context, text, "text/x.cucumber.log+plain")` —
  the media type reference Cucumber implementations use for `log`.
  Returns the context unchanged.
  """
  @spec log(map(), String.t()) :: map()
  def log(context, text) when is_binary(text) do
    attach(context, text, "text/x.cucumber.log+plain")
  end

  @doc """
  Attaches a link to the current step.

  Convenience for `attach(context, uri, "text/uri-list")` — the media type
  reference Cucumber implementations use for `link`. Returns the context
  unchanged.
  """
  @spec link(map(), String.t()) :: map()
  def link(context, uri) when is_binary(uri) do
    attach(context, uri, "text/uri-list")
  end

  defp record_attachment(context, body, media_type, encoding, opts) do
    step = if context[:cucumber_phase] == :step, do: context[:step]

    attachment = %Cucumber.Attachment{
      body: body,
      media_type: media_type,
      encoding: encoding,
      filename: opts[:filename],
      feature_file: Map.get(context, :feature_file),
      scenario_name: Map.get(context, :scenario_name),
      step_text: step && step.text,
      step_line: step && step.line,
      phase: Map.get(context, :cucumber_phase),
      attempt: Map.get(context, :retry_attempt)
    }

    # The message ref (current testCaseStarted/testStep ids, set by the
    # runner) places the attachment envelope in the message stream
    Cucumber.RunCoordinator.record_attachment(
      attachment,
      Map.get(context, :cucumber_message_ref)
    )

    context
  end
end
