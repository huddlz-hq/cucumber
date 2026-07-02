defmodule Cucumber.Behavior.MarkdownTest do
  @moduledoc """
  Behavior tests for Markdown feature files (#29): a `.feature.md` source
  compiles and runs exactly like its plain Gherkin equivalent — outlines
  expand, backgrounds run first, docstrings and data tables reach the step
  context, failures point at the Markdown source line, and the Cucumber
  Messages stream carries the Markdown media type.
  """

  use Cucumber.BehaviorCase

  defmodule Steps do
    use Cucumber.StepDefinition
    import ExUnit.Assertions

    step "the register is empty", _context do
      Collector.record(:background)
      %{items: []}
    end

    step "this receipt:", context do
      Collector.record({:docstring, context.docstring_media_type})
      assert context.docstring == "2x cucumber @ 1.50"
      :ok
    end

    step "these prices:", context do
      Collector.record(:prices)
      assert context.datatable.maps == [%{"item" => "cucumber", "price" => "1.50"}]
      :ok
    end

    step "checkout {word}", %{args: [outcome]} = context do
      Collector.record({:checkout, outcome})

      if outcome == "explodes" do
        raise "til failure"
      end

      context
    end
  end

  test "a Markdown feature runs end to end: background, docstring, table, outline expansion" do
    result =
      run_markdown(
        """
        # Feature: Markdown checkout

        This prose is documentation, not Gherkin.

        ## Background:

        * Given the register is empty

        ## Rule: Receipts add up

        ### Scenario Outline: checkout

        * Given this receipt:
          ```text
          2x cucumber @ 1.50
          ```
        * And these prices:
          | item     | price |
          | -------- | ----- |
          | cucumber | 1.50  |
        * When checkout <outcome>

        #### Examples:

          | outcome  |
          | -------- |
          | succeeds |
          | explodes |
        """,
        # Examples-row definition order, so the events list is deterministic.
        seed: 0
      )

    assert result.total == 2
    assert result.failures == 1

    assert result.events == [
             :background,
             {:docstring, "text"},
             :prices,
             {:checkout, "succeeds"},
             :background,
             {:docstring, "text"},
             :prices,
             {:checkout, "explodes"}
           ]
  end

  test "a failing step's stack frame points at the .feature.md source line" do
    file = unique_markdown_path()

    result =
      run_markdown(
        """
        # Feature: Truthful lines
        ## Scenario: exploding checkout
        * Given the register is empty
        * When checkout explodes
        """,
        file: file
      )

    assert result.failures == 1
    # The `When checkout explodes` step is on (1-based) line 4 of the file.
    assert result.output =~ "#{file}:4"
  end

  test "generated module names strip the .feature.md extension" do
    result =
      run_markdown(
        """
        # Feature: Module naming
        ## Scenario: s
        * Given the register is empty
        """,
        file: "test/fixtures/generated/checkout_flow.feature.md"
      )

    assert result.failures == 0
    assert Atom.to_string(result.module) == "Test.Fixtures.Generated.CheckoutFlowTest"
  end

  test "a .feature and a .feature.md with the same basename fail loudly, not silently" do
    # Both would compile to the same test module; redefinition would drop
    # the first file's scenarios from the run.
    plain = """
    Feature: Plain checkout
    Scenario: from plain
      Given the register is empty
    """

    markdown = """
    # Feature: Markdown checkout
    ## Scenario: from markdown
    * Given the register is empty
    """

    message =
      ~r/checkout\.feature and .*checkout\.feature\.md would generate the same test module/

    assert_raise ArgumentError, message, fn ->
      run_features([plain, markdown],
        steps: [Steps],
        files: [
          "test/fixtures/generated/collision/checkout.feature",
          "test/fixtures/generated/collision/checkout.feature.md"
        ]
      )
    end
  end

  test "the messages stream carries the Markdown media type and .feature.md uri" do
    file = unique_markdown_path()

    path =
      Path.join(
        System.tmp_dir!(),
        "markdown_messages_#{System.unique_integer([:positive])}.ndjson"
      )

    on_exit(fn -> File.rm(path) end)

    result =
      run_markdown(
        """
        # Feature: Media type
        ## Scenario: s
        * Given the register is empty
        """,
        file: file,
        messages: path
      )

    assert result.failures == 0

    assert [%{"source" => source}] = for(%{"source" => _} = e <- result.messages, do: e)
    assert source["uri"] == file
    assert source["mediaType"] == "text/x.cucumber.gherkin+markdown"
    assert source["data"] =~ "# Feature: Media type"

    assert [%{"gherkinDocument" => document}] =
             for(%{"gherkinDocument" => _} = e <- result.messages, do: e)

    assert document["uri"] == file
  end

  defp run_markdown(source, opts) do
    opts = Keyword.put_new_lazy(opts, :file, &unique_markdown_path/0)
    run_feature(source, Keyword.put(opts, :steps, [Steps]))
  end

  defp unique_markdown_path do
    "test/fixtures/generated/behavior_#{System.unique_integer([:positive])}.feature.md"
  end
end
