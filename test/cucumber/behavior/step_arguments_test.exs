defmodule Cucumber.Behavior.StepArgumentsTest do
  @moduledoc """
  Behavior tests for step arguments: a data table and a doc string reach
  only the step they are written under — together, in either order, from
  `.feature` and `.feature.md` sources alike — and the emitted pickle
  records their argument order.
  """

  use Cucumber.BehaviorCase

  defmodule Steps do
    use Cucumber.StepDefinition

    step "a step with {word}", %{args: [label]} = context do
      Collector.record(
        {label, get_in(context, [:datatable, :raw]), context[:docstring],
         context[:docstring_media_type]}
      )

      :ok
    end
  end

  test "a step sees only its own arguments, never an earlier step's" do
    run =
      run_feature(
        """
        Feature: Argument scope

          Scenario: s
            Given a step with both
              | table |
              ```text
              doc
              ```
            And a step with table
              | only table |
            And a step with docstring
              \"\"\"
              only doc
              \"\"\"
            And a step with nothing
        """,
        steps: [Steps]
      )

    assert run.failures == 0

    assert run.events == [
             {"both", [["table"]], "doc", "text"},
             {"table", [["only table"]], nil, nil},
             {"docstring", nil, "only doc", nil},
             {"nothing", nil, nil, nil}
           ]
  end

  @tag :tmp_dir
  test "the emitted pickle numbers both arguments by source order", %{tmp_dir: tmp_dir} do
    run =
      run_with_messages(
        tmp_dir,
        """
        Feature: Argument order

          Scenario: s
            Given a step with table-first
              | hello |
              \"\"\"
              world
              \"\"\"
            And a step with doc-first
              \"\"\"
              hello
              \"\"\"
              | world |
            And a step with table-only
              | alone |
        """,
        "feature"
      )

    assert run.failures == 0

    assert pickle_arguments(run.messages) == [
             %{
               "dataTable" => %{"argumentIndex" => 1, "rows" => [cells(["hello"])]},
               "docString" => %{"argumentIndex" => 2, "content" => "world"}
             },
             %{
               "docString" => %{"argumentIndex" => 1, "content" => "hello"},
               "dataTable" => %{"argumentIndex" => 2, "rows" => [cells(["world"])]}
             },
             %{"dataTable" => %{"rows" => [cells(["alone"])]}}
           ]
  end

  @tag :tmp_dir
  test "a Markdown step's arguments run and are numbered by source order", %{tmp_dir: tmp_dir} do
    run =
      run_with_messages(
        tmp_dir,
        """
        # Feature: Argument order

        ## Scenario: s

        * Given a step with table-first
          | hello |
          ```
          world
          ```
        * And a step with doc-first
          ```
          hello
          ```
          | world |
        """,
        "feature.md"
      )

    assert run.failures == 0

    assert run.events == [
             {"table-first", [["hello"]], "world", nil},
             {"doc-first", [["world"]], "hello", nil}
           ]

    assert pickle_arguments(run.messages) == [
             %{
               "dataTable" => %{"argumentIndex" => 1, "rows" => [cells(["hello"])]},
               "docString" => %{"argumentIndex" => 2, "content" => "world"}
             },
             %{
               "docString" => %{"argumentIndex" => 1, "content" => "hello"},
               "dataTable" => %{"argumentIndex" => 2, "rows" => [cells(["world"])]}
             }
           ]
  end

  defp run_with_messages(tmp_dir, source, extension) do
    file =
      "test/fixtures/generated/step_arguments_#{System.unique_integer([:positive])}.#{extension}"

    messages = Path.join(tmp_dir, "messages.ndjson")
    run = run_feature(source, steps: [Steps], file: file, messages: messages)
    Cucumber.CckStream.assert_valid(run.messages)
    run
  end

  defp pickle_arguments(messages) do
    for %{"pickle" => pickle} <- messages, step <- pickle["steps"], do: step["argument"]
  end

  defp cells(values), do: %{"cells" => Enum.map(values, &%{"value" => &1})}
end
