defmodule Cucumber.CckApprovalTest do
  @moduledoc """
  CCK approval suite: runs every supported Cucumber Compatibility Kit
  sample through the real pipeline with the Cucumber Messages sink enabled
  and compares the emitted NDJSON stream against the kit's reference
  stream, normalized by `Cucumber.CckApproval`.

  Feature sources and reference `.ndjson` files are vendored under
  `test/fixtures/cck/`; the Elixir equivalents of the kit's TypeScript
  step definitions live in `Cucumber.CckApproval.Definitions`.

  ## Filtered samples

  Samples the CCK ships that are deliberately not approved here, with the
  reason:

    * `unknown-parameter-type` — the reference implementation runs the
      scenario and emits an `undefinedParameterType` envelope; this
      implementation raises `Cucumber.UndefinedParameterTypeError` at
      discovery, before a run exists (behavior covered in
      `test/cucumber/behavior/parameter_types_test.exs`)
    * `pending-exception`, `skipped-exception` — pending/skipped are
      return values here (`:pending`/`:skipped`), not throwable
      exceptions; the equivalent behavior is approved via the `pending`
      and `skipped` samples
    * `test-run-exception` — simulates a runner-internal crash via the
      reference CLI's `--error` flag; no equivalent injection point
    * `multiple-features-reversed` — exercises the reference CLI's
      `--order reverse`; execution order here is ExUnit's (the plain
      `multiple-features` sample is approved)
    * `global-hooks-attachments` — attachments from BeforeAll/AfterAll
      hooks (`attachment.testRunHookStartedId`) are not supported

  Per-sample comparison allowances (the `:drop` / `:drop_feature_description`
  / `:drop_step_definition_patterns` options below) are documented inline.
  """

  use Cucumber.BehaviorCase

  alias Cucumber.CckApproval
  alias Cucumber.CckApproval.Definitions

  # {sample, run options}. Options besides :steps/:hooks/:parameter_types:
  #   :retry - sets `config :cucumber, retry: N` for the run (the CCK runs
  #     these samples with `--retry 2`)
  #   :drop / :drop_feature_description / :drop_step_definition_patterns -
  #     comparison allowances, passed through to Cucumber.CckApproval
  #     (justify inline!)
  @samples [
    {"minimal", steps: [Definitions.Minimal]},
    {"cdata", steps: [Definitions.Cdata]},
    {"empty", steps: []},
    {"data-tables", steps: [Definitions.DataTables]},
    {"backgrounds", steps: [Definitions.Backgrounds]},
    {"doc-strings", steps: [Definitions.DocStrings]},
    {"examples-tables", steps: [Definitions.ExamplesTables]},
    {"unused-steps", steps: [Definitions.UnusedSteps]},
    {"stack-traces", steps: [Definitions.StackTraces]},
    {"undefined", steps: [Definitions.Undefined]},
    {"ambiguous", steps: [Definitions.Ambiguous]},
    {"pending", steps: [Definitions.Pending]},
    {"skipped", steps: [Definitions.Skipped]},
    {"all-statuses", steps: [Definitions.AllStatuses]},
    # Same six step definitions as all-statuses in the reference, too.
    {"failedish-combinations", steps: [Definitions.AllStatuses]},
    {"hooks", steps: [Definitions.Hooks], hooks: [Definitions.HooksHooks]},
    {"hooks-conditional",
     steps: [Definitions.PassingStep], hooks: [Definitions.HooksConditionalHooks]},
    {"hooks-named", steps: [Definitions.PassingStep], hooks: [Definitions.HooksNamedHooks]},
    {"hooks-skipped",
     steps: [Definitions.HooksSkipped],
     hooks: [
       Definitions.HooksSkippedHooks1,
       Definitions.HooksSkippedHooks2,
       Definitions.HooksSkippedHooks3
     ]},
    {"skipped-failing-hook",
     steps: [Definitions.SkippedFailingHook], hooks: [Definitions.SkippedFailingHookHooks]},
    {"global-hooks",
     steps: [Definitions.GlobalHooks],
     hooks: [Definitions.GlobalHooksHooks1, Definitions.GlobalHooksHooks2]},
    # The reference aborts the run when a BeforeAll hook fails — no test
    # cases exist. Here scenarios are ExUnit tests, which always run (and
    # fail with Cucumber.BeforeAllError), so the case/step envelopes are
    # ours alone; the run-level stream (hooks incl. the FAILED one, and
    # testRunFinished success: false) is what's compared.
    {"global-hooks-beforeall-error",
     steps: [Definitions.GlobalHooksErrorSteps],
     hooks: [
       Definitions.GlobalHooksHooks1,
       Definitions.ExplodingBeforeAllHooks,
       Definitions.TrailingBeforeAllHooks
     ],
     drop: ~w(testCase testCaseStarted testStepStarted testStepFinished testCaseFinished)},
    # The AfterAll failure surfaces as a raise when the nested run
    # finishes — after the NDJSON stream is flushed.
    {"global-hooks-afterall-error",
     steps: [Definitions.GlobalHooksErrorSteps],
     hooks: [
       Definitions.GlobalHooksHooks1,
       Definitions.ExplodingAfterAllHooks,
       Definitions.TrailingAfterAllHooks
     ],
     raises: "AfterAll hook went wrong"},
    {"parameter-types",
     steps: [Definitions.ParameterTypesSteps], parameter_types: [Definitions.ParameterTypesTypes]},
    {"regular-expression", steps: [Definitions.RegularExpression]},
    {"retry", steps: [Definitions.Retry], retry: 2},
    # The reference registers the same expression twice; discovery rejects
    # exact duplicates, so the ambiguity comes from two overlapping
    # patterns and the (necessarily different) pattern sources are ignored.
    {"retry-ambiguous",
     steps: [Definitions.RetryAmbiguous], retry: 2, drop_step_definition_patterns: true},
    {"retry-pending", steps: [Definitions.RetryPending], retry: 2},
    {"retry-undefined", steps: [], retry: 2},
    {"rules", steps: [Definitions.Rules]},
    {"rules-backgrounds", steps: [Definitions.Backgrounds]},
    {"attachments", steps: [Definitions.Attachments]},
    {"undefined-multiple", steps: [Definitions.Undefined]},
    {"hooks-undefined", steps: [], hooks: [Definitions.HooksHooks]},
    {"hooks-attachment",
     steps: [Definitions.PassingStep], hooks: [Definitions.AttachingScenarioHooks]},
    {"examples-tables-undefined", steps: [Definitions.ExamplesTablesUndefined]},
    {"examples-tables-undefined-multiple", steps: [Definitions.ExamplesTablesUndefined]},
    {"examples-tables-attachment", steps: [Definitions.ExamplesTablesAttachment]},
    {"multiple-features",
     steps: [Definitions.MultipleFeatures],
     files: [
       "multiple-features-1.feature",
       "multiple-features-2.feature",
       "multiple-features-3.feature"
     ]},
    # The reference stream's feature description ("| boz | boo |") is an
    # emergent quirk of the reference tokenizer's error recovery, not MDG
    # behavior — Gherkin.Markdown deliberately captures no markdown
    # descriptions (see its moduledoc), so that one field is excluded.
    {"markdown",
     steps: [Definitions.Markdown], files: ["markdown.feature.md"], drop_feature_description: true}
  ]

  for {sample, opts} <- @samples do
    @sample sample
    @opts opts

    test "CCK approval: #{sample}" do
      approve(@sample, @opts)
    end
  end

  defp approve(sample, opts) do
    path =
      Path.join(
        System.tmp_dir!(),
        "cck_approval_#{System.unique_integer([:positive])}.ndjson"
      )

    on_exit(fn -> File.rm(path) end)

    file_names = Keyword.get(opts, :files, ["#{sample}.feature"])
    sources = Enum.map(file_names, &fixture(sample, &1))

    # Unique per run so the generated modules can't collide with other
    # tests compiling the same fixtures; comparison reduces uris to their
    # basename, which this preserves.
    unique_dir = "test/fixtures/generated/approval_#{System.unique_integer([:positive])}"

    run = fn ->
      with_retry_config(opts[:retry], fn ->
        run_features(sources,
          steps: Keyword.get(opts, :steps, []),
          hooks: Keyword.get(opts, :hooks, []),
          parameter_types: Keyword.get(opts, :parameter_types, []),
          files: Enum.map(file_names, &Path.join(unique_dir, &1)),
          messages: path,
          seed: 0
        )
      end)
    end

    # An AfterAll failure raises when the nested run finishes; the message
    # stream is flushed before the raise, so the comparison still runs.
    case opts[:raises] do
      nil -> run.()
      message -> assert_raise(RuntimeError, message, run)
    end

    CckApproval.assert_equivalent(
      decode(File.read!(path)),
      reference(sample),
      Keyword.take(opts, [:drop, :drop_feature_description, :drop_step_definition_patterns])
    )
  end

  defp decode(ndjson) do
    ndjson
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp reference(sample) do
    ["test/fixtures/cck", sample, "#{sample}.ndjson"]
    |> Path.join()
    |> File.read!()
    |> decode()
  end

  defp with_retry_config(nil, fun), do: fun.()

  defp with_retry_config(retries, fun) do
    previous = Application.fetch_env(:cucumber, :retry)
    Application.put_env(:cucumber, :retry, retries)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:cucumber, :retry, value)
        :error -> Application.delete_env(:cucumber, :retry)
      end
    end
  end
end
