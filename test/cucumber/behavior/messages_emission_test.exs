defmodule Cucumber.Behavior.MessagesEmissionTest do
  @moduledoc """
  Behavior tests for the dynamic Cucumber Messages layer: given a feature
  and step definitions run with the message sink enabled, the emitted
  NDJSON stream has the right envelopes, in the right order, with the right
  statuses — including for failing, pending, skipped, undefined, ambiguous,
  retried, and crashed scenarios.
  """

  use Cucumber.BehaviorCase

  defmodule Steps do
    use Cucumber.StepDefinition

    step "a background step", _context do
      :ok
    end

    step "a passing step", _context do
      :ok
    end

    step "another passing step", _context do
      :ok
    end

    step "I have {int} cukes", _context do
      :ok
    end

    step "a failing step", _context do
      raise "boom"
    end

    step "a pending step", _context do
      {:pending, "todo"}
    end

    step "a skipping step", _context do
      {:skipped, "not on this platform"}
    end

    step "a flaky step", context do
      if context.retry_attempt == 1, do: raise("flaky"), else: :ok
    end

    step "an attaching step", context do
      context
      |> Cucumber.attach("plain note", "text/plain")
      |> Cucumber.attach({:bytes, <<1, 2, 3>>}, "application/octet-stream", filename: "b.bin")
    end

    step "a lethal step", _context do
      Process.exit(self(), :kill)
    end
  end

  defmodule AmbiguousSteps do
    use Cucumber.StepDefinition

    step "an ambiguous thing", _context do
      :ok
    end

    step "an ambiguous {word}", _context do
      :ok
    end
  end

  defmodule ScenarioHooks do
    use Cucumber.Hooks

    before_scenario context, name: "prepare" do
      {:ok, context}
    end

    after_scenario _context do
      :ok
    end
  end

  defmodule FailingBeforeHook do
    use Cucumber.Hooks

    before_scenario _context do
      {:error, :database_down}
    end
  end

  defmodule FailingAfterAllHook do
    use Cucumber.Hooks

    after_all _context do
      raise "cleanup exploded"
    end
  end

  defmodule RunHooks do
    use Cucumber.Hooks

    before_all context do
      {:ok, context}
    end

    after_all _context do
      :ok
    end
  end

  defmodule SkippingAfterHook do
    use Cucumber.Hooks

    after_scenario _context do
      {:skipped, "cleanup not needed"}
    end
  end

  defmodule AttachingAfterHook do
    use Cucumber.Hooks

    after_scenario context do
      Cucumber.attach(context, "teardown evidence", "text/plain")
      :ok
    end
  end

  defmodule RaisingAfterStep do
    use Cucumber.Hooks

    after_step _context do
      raise "after step exploded"
    end
  end

  defmodule RaisingBeforeStep do
    use Cucumber.Hooks

    before_step _context do
      raise "before step exploded"
    end
  end

  defmodule AttachingAfterStep do
    use Cucumber.Hooks

    after_step context do
      Cucumber.attach(context, "post-step note", "text/plain")
      :ok
    end
  end

  # --- Harness helpers ---

  defp run_messages(sources, opts) do
    path =
      Path.join(
        System.tmp_dir!(),
        "cucumber_messages_#{System.unique_integer([:positive])}.ndjson"
      )

    on_exit(fn -> File.rm(path) end)
    run_features(List.wrap(sources), Keyword.put(opts, :messages, path))
  end

  defp envelope_types(messages) do
    Enum.map(messages, fn envelope -> envelope |> Map.keys() |> hd() end)
  end

  defp payloads(messages, type) do
    for %{^type => payload} <- messages, do: payload
  end

  # Every testStepFinished as {label, status} in emission order, where label
  # is the pickle step's text or :hook for scenario-hook steps.
  defp finished_steps(messages) do
    step_texts =
      for %{"pickle" => pickle} <- messages,
          step <- pickle["steps"],
          into: %{},
          do: {step["id"], step["text"]}

    test_steps =
      for %{"testCase" => test_case} <- messages,
          step <- test_case["testSteps"],
          into: %{},
          do: {step["id"], step}

    for %{"testStepFinished" => finished} <- messages do
      label =
        case test_steps[finished["testStepId"]] do
          %{"pickleStepId" => pickle_step_id} -> step_texts[pickle_step_id]
          %{"hookId" => _hook_id} -> :hook
        end

      {label, finished["testStepResult"]["status"]}
    end
  end

  # Recursively collects declared ids ("id" keys) and references (keys
  # ending in Id/Ids) from decoded envelopes.
  defp walk_ids(value, acc \\ {[], []})

  defp walk_ids(value, acc) when is_map(value) do
    Enum.reduce(value, acc, fn
      {"id", id}, {ids, refs} ->
        {[id | ids], refs}

      {key, val}, {ids, refs} = acc ->
        cond do
          String.ends_with?(key, "Id") and is_binary(val) -> {ids, [val | refs]}
          String.ends_with?(key, "Ids") and is_list(val) -> {ids, val ++ refs}
          true -> walk_ids(val, acc)
        end
    end)
  end

  defp walk_ids(value, acc) when is_list(value), do: Enum.reduce(value, acc, &walk_ids(&1, &2))
  defp walk_ids(_value, acc), do: acc

  # --- Tests ---

  test "a passing run emits the full stream in order" do
    run =
      run_messages(
        """
        Feature: ordering
          Background:
            Given a background step
          Scenario: first
            When a passing step
        """,
        steps: [Steps]
      )

    assert run.passed == 1

    definition_count = length(Steps.__cucumber_steps__())

    assert envelope_types(run.messages) ==
             ["meta", "source", "gherkinDocument", "pickle"] ++
               List.duplicate("stepDefinition", definition_count) ++
               [
                 "testRunStarted",
                 "testCase",
                 "testCaseStarted",
                 "testStepStarted",
                 "testStepFinished",
                 "testStepStarted",
                 "testStepFinished",
                 "testCaseFinished",
                 "testRunFinished"
               ]

    assert finished_steps(run.messages) == [
             {"a background step", "PASSED"},
             {"a passing step", "PASSED"}
           ]

    [run_finished] = payloads(run.messages, "testRunFinished")
    assert run_finished["success"] == true

    [step_finished | _rest] = payloads(run.messages, "testStepFinished")
    assert %{"seconds" => _, "nanos" => _} = step_finished["testStepResult"]["duration"]
  end

  test "every id is unique and every reference resolves" do
    run =
      run_messages(
        """
        @wip
        Feature: rich
          Background:
            Given a background step
          Rule: outlines
            Scenario Outline: rows
              Given a passing step
              And I have <n> cukes
              Examples:
                | n |
                | 1 |
                | 2 |
        """,
        steps: [Steps],
        hooks: [ScenarioHooks, RunHooks]
      )

    assert run.passed == 2

    {ids, refs} = walk_ids(run.messages)

    assert Enum.uniq(ids) == ids
    id_set = MapSet.new(ids)

    for ref <- refs do
      assert MapSet.member?(id_set, ref), "referenced id #{inspect(ref)} does not exist"
    end
  end

  test "a failure mid-scenario marks the step FAILED and the rest SKIPPED" do
    run =
      run_messages(
        """
        Feature: failing
          Scenario: fails midway
            Given a passing step
            When a failing step
            Then another passing step
        """,
        steps: [Steps]
      )

    assert run.failures == 1

    assert finished_steps(run.messages) == [
             {"a passing step", "PASSED"},
             {"a failing step", "FAILED"},
             {"another passing step", "SKIPPED"}
           ]

    failed =
      Enum.find(payloads(run.messages, "testStepFinished"), fn finished ->
        finished["testStepResult"]["status"] == "FAILED"
      end)

    assert failed["testStepResult"]["message"] =~ "boom"

    [run_finished] = payloads(run.messages, "testRunFinished")
    assert run_finished["success"] == false
  end

  test "pending and skipped signals carry their statuses" do
    run =
      run_messages(
        """
        Feature: signals
          Scenario: pending midway
            Given a passing step
            When a pending step
            Then another passing step
        """,
        steps: [Steps]
      )

    assert run.failures == 1

    assert finished_steps(run.messages) == [
             {"a passing step", "PASSED"},
             {"a pending step", "PENDING"},
             {"another passing step", "SKIPPED"}
           ]

    run =
      run_messages(
        """
        Feature: signals
          Scenario: skipped midway
            Given a skipping step
            Then another passing step
        """,
        steps: [Steps]
      )

    # A skipped scenario is not a failure — the run stays green
    assert run.passed == 1

    assert finished_steps(run.messages) == [
             {"a skipping step", "SKIPPED"},
             {"another passing step", "SKIPPED"}
           ]

    [run_finished] = payloads(run.messages, "testRunFinished")
    assert run_finished["success"] == true
  end

  test "unexecuted unmatched steps keep UNDEFINED/AMBIGUOUS after a failed-ish stop, but not after a skip" do
    # CCK failedish-combinations semantics: a step that can never match
    # stays UNDEFINED/AMBIGUOUS when the scenario stopped for a failed-ish
    # reason (failure, pending, undefined, ambiguous)...
    run =
      run_messages(
        """
        Feature: failedish
          Scenario: failure first
            Given a failing step
            And a step nobody defined
            And an ambiguous thing
        """,
        steps: [Steps, AmbiguousSteps]
      )

    assert finished_steps(run.messages) == [
             {"a failing step", "FAILED"},
             {"a step nobody defined", "UNDEFINED"},
             {"an ambiguous thing", "AMBIGUOUS"}
           ]

    # ...but after a deliberate skip, nothing that follows runs *by
    # design*, so everything — matched or not — is SKIPPED.
    run =
      run_messages(
        """
        Feature: failedish
          Scenario: skip first
            Given a skipping step
            And a step nobody defined
        """,
        steps: [Steps]
      )

    assert finished_steps(run.messages) == [
             {"a skipping step", "SKIPPED"},
             {"a step nobody defined", "SKIPPED"}
           ]
  end

  test "failed-ish stops that bypass the runner's skip pass still report unmatched steps UNDEFINED" do
    # A raising background step and a failing before-scenario hook both
    # abort before the runner's skip_unexecuted_steps call; their cases
    # close through the coordinator's close_test_case synthesis, which
    # must apply the same match-status overrides.
    run =
      run_messages(
        """
        Feature: failedish via background
          Background:
            Given a failing step

          Scenario: never reaches its steps
            Given a step nobody defined
        """,
        steps: [Steps]
      )

    assert finished_steps(run.messages) == [
             {"a failing step", "FAILED"},
             {"a step nobody defined", "UNDEFINED"}
           ]

    run =
      run_messages(
        """
        Feature: failedish via before hook
          Scenario: never starts
            Given a step nobody defined
        """,
        steps: [Steps],
        hooks: [FailingBeforeHook]
      )

    assert {:hook, "FAILED"} in finished_steps(run.messages)
    assert {"a step nobody defined", "UNDEFINED"} in finished_steps(run.messages)
  end

  test "a failing after_all hook fails the run in testRunFinished even when every scenario passed" do
    path =
      Path.join(
        System.tmp_dir!(),
        "cucumber_messages_#{System.unique_integer([:positive])}.ndjson"
      )

    on_exit(fn -> File.rm(path) end)

    # The after_all error surfaces as a raise when the nested run
    # finishes; the stream is flushed first.
    assert_raise RuntimeError, "cleanup exploded", fn ->
      run_features(
        [
          """
          Feature: green
            Scenario: passes
              Given a passing step
          """
        ],
        steps: [Steps],
        hooks: [FailingAfterAllHook],
        messages: path
      )
    end

    messages =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    [hook_finished] = payloads(messages, "testRunHookFinished")
    assert hook_finished["result"]["status"] == "FAILED"

    [run_finished] = payloads(messages, "testRunFinished")
    assert run_finished["success"] == false
  end

  test "undefined and ambiguous steps get their statuses and definition ids" do
    run =
      run_messages(
        """
        Feature: undefined
          Scenario: nobody wrote this
            Given a step nobody defined
            Then another passing step
        """,
        steps: [Steps]
      )

    assert run.failures == 1

    assert finished_steps(run.messages) == [
             {"a step nobody defined", "UNDEFINED"},
             {"another passing step", "SKIPPED"}
           ]

    [test_case] = payloads(run.messages, "testCase")
    [undefined_step | _rest] = test_case["testSteps"]
    assert undefined_step["stepDefinitionIds"] == []

    run =
      run_messages(
        """
        Feature: ambiguous
          Scenario: two patterns match
            Given an ambiguous thing
        """,
        steps: [AmbiguousSteps]
      )

    assert run.failures == 1
    assert finished_steps(run.messages) == [{"an ambiguous thing", "AMBIGUOUS"}]

    # Both matching definitions are referenced from the test step
    [test_case] = payloads(run.messages, "testCase")
    [ambiguous_step] = test_case["testSteps"]
    assert length(ambiguous_step["stepDefinitionIds"]) == 2
  end

  test "a matched step references its step definition" do
    run =
      run_messages(
        """
        Feature: match
          Scenario: one definition
            Given a passing step
        """,
        steps: [Steps]
      )

    definitions =
      for %{"stepDefinition" => definition} <- run.messages,
          into: %{},
          do: {definition["id"], definition["pattern"]["source"]}

    [test_case] = payloads(run.messages, "testCase")
    [step] = test_case["testSteps"]

    assert [definition_id] = step["stepDefinitionIds"]
    assert definitions[definition_id] == "a passing step"
  end

  test "a retried scenario reuses its test case across attempts" do
    run =
      run_messages(
        """
        Feature: retry
          @retry-1
          Scenario: flaky
            Given a flaky step
        """,
        steps: [Steps]
      )

    assert run.passed == 1

    assert [test_case] = payloads(run.messages, "testCase")

    [first, second] = payloads(run.messages, "testCaseStarted")
    assert first["attempt"] == 0
    assert second["attempt"] == 1
    assert first["testCaseId"] == test_case["id"]
    assert second["testCaseId"] == test_case["id"]

    [first_finish, second_finish] = payloads(run.messages, "testCaseFinished")
    assert first_finish["willBeRetried"] == true
    assert second_finish["willBeRetried"] == false

    statuses_by_attempt =
      for %{"testStepFinished" => finished} <- run.messages do
        {finished["testCaseStartedId"], finished["testStepResult"]["status"]}
      end

    assert statuses_by_attempt == [
             {first["id"], "FAILED"},
             {second["id"], "PASSED"}
           ]
  end

  test "scenario hooks become hook envelopes and hook test steps" do
    run =
      run_messages(
        """
        Feature: hooks
          Scenario: hooked
            Given a passing step
        """,
        steps: [Steps],
        hooks: [ScenarioHooks]
      )

    assert run.passed == 1

    hooks = payloads(run.messages, "hook")
    assert Enum.map(hooks, & &1["type"]) == ["BEFORE_TEST_CASE", "AFTER_TEST_CASE"]
    assert hd(hooks)["name"] == "prepare"

    [test_case] = payloads(run.messages, "testCase")
    [before_step, pickle_step, after_step] = test_case["testSteps"]
    assert before_step["hookId"] == hd(hooks)["id"]
    assert Map.has_key?(pickle_step, "pickleStepId")
    assert after_step["hookId"] == List.last(hooks)["id"]

    assert finished_steps(run.messages) == [
             {:hook, "PASSED"},
             {"a passing step", "PASSED"},
             {:hook, "PASSED"}
           ]
  end

  test "a failing before hook fails its test step and skips the scenario's steps" do
    run =
      run_messages(
        """
        Feature: hook failure
          Scenario: never runs
            Given a passing step
        """,
        steps: [Steps],
        hooks: [FailingBeforeHook]
      )

    assert run.failures == 1

    assert finished_steps(run.messages) == [
             {:hook, "FAILED"},
             {"a passing step", "SKIPPED"}
           ]

    # The failure cause reaches the stream
    failed_hook =
      Enum.find(payloads(run.messages, "testStepFinished"), fn finished ->
        finished["testStepResult"]["status"] == "FAILED"
      end)

    assert failed_hook["testStepResult"]["message"] =~ "database_down"
  end

  test "an after hook returning :skipped marks only its own test step" do
    run =
      run_messages(
        """
        Feature: skipping teardown
          Scenario: passes anyway
            Given a passing step
        """,
        steps: [Steps],
        hooks: [SkippingAfterHook]
      )

    # The hook signal marks the hook step, not the scenario (CCK semantics)
    assert run.passed == 1

    assert finished_steps(run.messages) == [
             {"a passing step", "PASSED"},
             {:hook, "SKIPPED"}
           ]

    skipped_hook =
      Enum.find(payloads(run.messages, "testStepFinished"), fn finished ->
        finished["testStepResult"]["status"] == "SKIPPED"
      end)

    assert skipped_hook["testStepResult"]["message"] == "cleanup not needed"
  end

  test "attachments from an after hook reference the hook's own test step" do
    # The background matters: its last step used to leave a stale message
    # ref in the context the after hooks receive
    run =
      run_messages(
        """
        Feature: teardown evidence
          Background:
            Given a background step
          Scenario: attaches on teardown
            Given a passing step
        """,
        steps: [Steps],
        hooks: [AttachingAfterHook]
      )

    assert run.passed == 1

    [attachment] = payloads(run.messages, "attachment")
    [test_case] = payloads(run.messages, "testCase")

    after_hook_step = List.last(test_case["testSteps"])
    assert Map.has_key?(after_hook_step, "hookId")
    assert attachment["testStepId"] == after_hook_step["id"]

    [case_started] = payloads(run.messages, "testCaseStarted")
    assert attachment["testCaseStartedId"] == case_started["id"]
  end

  test "skipped steps are emitted before the after-hook events" do
    run =
      run_messages(
        """
        Feature: ordering under failure
          Scenario: fails midway
            Given a failing step
            Then another passing step
        """,
        steps: [Steps],
        hooks: [ScenarioHooks]
      )

    assert run.failures == 1

    # Emission order: before hook, failing step, remaining step SKIPPED,
    # then the after hook — reference ordering, not SKIPPED-after-teardown
    assert finished_steps(run.messages) == [
             {:hook, "PASSED"},
             {"a failing step", "FAILED"},
             {"another passing step", "SKIPPED"},
             {:hook, "PASSED"}
           ]
  end

  test "an after_step hook raising reports the step FAILED, not UNKNOWN" do
    run =
      run_messages(
        """
        Feature: exploding step hook
          Scenario: body passes
            Given a passing step
        """,
        steps: [Steps],
        hooks: [RaisingAfterStep]
      )

    assert run.failures == 1
    assert finished_steps(run.messages) == [{"a passing step", "FAILED"}]

    [finished] = payloads(run.messages, "testStepFinished")
    assert finished["testStepResult"]["message"] =~ "after step exploded"
  end

  test "a before_step hook raising reports the step FAILED, not UNKNOWN" do
    run =
      run_messages(
        """
        Feature: exploding pre-step hook
          Scenario: body never runs
            Given a passing step
        """,
        steps: [Steps],
        hooks: [RaisingBeforeStep]
      )

    assert run.failures == 1
    assert finished_steps(run.messages) == [{"a passing step", "FAILED"}]

    [finished] = payloads(run.messages, "testStepFinished")
    assert finished["testStepResult"]["message"] =~ "before step exploded"
  end

  test "after_step hook attachments land inside the step's event window on both outcomes" do
    for {feature_step, status, expected_message} <- [
          {"a passing step", "PASSED", nil},
          {"a failing step", "FAILED", "boom"}
        ] do
      run =
        run_messages(
          """
          Feature: post-step evidence
            Scenario: one step
              Given #{feature_step}
          """,
          steps: [Steps],
          hooks: [AttachingAfterStep]
        )

      [attachment] = payloads(run.messages, "attachment")
      [finished] = payloads(run.messages, "testStepFinished")

      # The hook's attachment references the step and precedes its finished
      # event — same ordering whether the step passed or failed — and the
      # failed step keeps its own error message, not the hook's context
      assert attachment["testStepId"] == finished["testStepId"]
      assert finished["testStepResult"]["status"] == status

      if expected_message do
        assert finished["testStepResult"]["message"] =~ expected_message
      end

      types = envelope_types(run.messages)
      attachment_index = Enum.find_index(types, &(&1 == "attachment"))
      finished_index = Enum.find_index(types, &(&1 == "testStepFinished"))
      assert attachment_index > Enum.find_index(types, &(&1 == "testStepStarted"))
      assert attachment_index < finished_index
    end
  end

  test "run-level hooks emit testRunHook events inside the run envelope" do
    run =
      run_messages(
        """
        Feature: run hooks
          Scenario: plain
            Given a passing step
        """,
        steps: [Steps],
        hooks: [RunHooks]
      )

    assert run.passed == 1

    hooks = payloads(run.messages, "hook")
    assert Enum.map(hooks, & &1["type"]) == ["BEFORE_TEST_RUN", "AFTER_TEST_RUN"]

    [run_started] = payloads(run.messages, "testRunStarted")
    [before_started, after_started] = payloads(run.messages, "testRunHookStarted")

    assert before_started["testRunStartedId"] == run_started["id"]
    assert before_started["hookId"] == hd(hooks)["id"]
    assert after_started["hookId"] == List.last(hooks)["id"]

    for finished <- payloads(run.messages, "testRunHookFinished") do
      assert finished["result"]["status"] == "PASSED"
    end

    types = envelope_types(run.messages)
    first_hook_start = Enum.find_index(types, &(&1 == "testRunHookStarted"))

    last_hook_start =
      length(types) - 1 - Enum.find_index(Enum.reverse(types), &(&1 == "testRunHookStarted"))

    # before_all runs lazily before the first scenario — and before its
    # testCase envelope, matching reference ordering; after_all runs after
    # every test case, before testRunFinished
    assert first_hook_start > Enum.find_index(types, &(&1 == "testRunStarted"))
    assert first_hook_start < Enum.find_index(types, &(&1 == "testCase"))
    assert last_hook_start > Enum.find_index(types, &(&1 == "testCaseFinished"))
    assert last_hook_start < Enum.find_index(types, &(&1 == "testRunFinished"))
  end

  test "attachments reference their step and land between its events" do
    run =
      run_messages(
        """
        Feature: attach
          Scenario: attaching
            Given an attaching step
        """,
        steps: [Steps]
      )

    assert run.passed == 1

    [text_attachment, binary_attachment] = payloads(run.messages, "attachment")

    assert text_attachment["body"] == "plain note"
    assert text_attachment["contentEncoding"] == "IDENTITY"
    assert text_attachment["mediaType"] == "text/plain"

    assert binary_attachment["body"] == Base.encode64(<<1, 2, 3>>)
    assert binary_attachment["contentEncoding"] == "BASE64"
    assert binary_attachment["fileName"] == "b.bin"

    [case_started] = payloads(run.messages, "testCaseStarted")
    [test_case] = payloads(run.messages, "testCase")
    [step] = test_case["testSteps"]

    for attachment <- [text_attachment, binary_attachment] do
      assert attachment["testCaseStartedId"] == case_started["id"]
      assert attachment["testStepId"] == step["id"]
    end

    types = envelope_types(run.messages)
    attachment_index = Enum.find_index(types, &(&1 == "attachment"))
    assert attachment_index > Enum.find_index(types, &(&1 == "testStepStarted"))
    assert attachment_index < Enum.find_index(types, &(&1 == "testStepFinished"))
  end

  test "a killed test process is reconciled at flush time" do
    run =
      run_messages(
        """
        Feature: crash
          Scenario: dies
            Given a lethal step
            Then another passing step
        """,
        steps: [Steps]
      )

    assert run.failures == 1

    # The runner never finished the case: the started step gets UNKNOWN,
    # the never-started step gets a synthesized pair, and the case is closed
    assert finished_steps(run.messages) == [
             {"a lethal step", "UNKNOWN"},
             {"another passing step", "UNKNOWN"}
           ]

    assert [%{"willBeRetried" => false}] = payloads(run.messages, "testCaseFinished")

    types = envelope_types(run.messages)
    assert List.last(types) == "testRunFinished"

    [run_finished] = payloads(run.messages, "testRunFinished")
    assert run_finished["success"] == false
  end

  test "ids stay unique across features in one run" do
    features = [
      """
      Feature: alpha
        Scenario: a
          Given a passing step
      """,
      """
      Feature: beta
        Scenario: b
          Given another passing step
      """
    ]

    run = run_messages(features, steps: [Steps])

    assert run.passed == 2
    assert length(payloads(run.messages, "source")) == 2
    assert length(payloads(run.messages, "gherkinDocument")) == 2
    assert length(payloads(run.messages, "testCase")) == 2

    {ids, _refs} = walk_ids(run.messages)
    assert Enum.uniq(ids) == ids
  end

  test "config :cucumber, :messages enables the sink through compile_features!" do
    path =
      Path.join(
        System.tmp_dir!(),
        "cucumber_messages_#{System.unique_integer([:positive])}.ndjson"
      )

    Application.put_env(:cucumber, :messages, path)

    on_exit(fn ->
      Application.delete_env(:cucumber, :messages)
      File.rm(path)
    end)

    # Real pipeline end to end: discovery of a vendored fixture, static
    # emission at compile time, runner events, after_suite flush. With no
    # step definitions discovered, the one step is UNDEFINED.
    modules =
      Cucumber.Compiler.compile_features!(
        features: ["test/fixtures/cck/minimal/minimal.feature"],
        steps: [],
        support: []
      )

    {result, _output} = Cucumber.BehaviorCase.run_isolated(modules)
    assert result.failures == 1

    messages =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    types = envelope_types(messages)
    assert hd(types) == "meta"
    assert List.last(types) == "testRunFinished"
    assert "source" in types and "gherkinDocument" in types and "pickle" in types

    assert finished_steps(messages) == [{"I have 42 cukes in my belly", "UNDEFINED"}]

    [run_finished] = payloads(messages, "testRunFinished")
    assert run_finished["success"] == false
  end

  test "without the messages option no stream is written" do
    run =
      run_feature(
        """
        Feature: quiet
          Scenario: plain
            Given a passing step
        """,
        steps: [Steps]
      )

    assert run.passed == 1
    assert run.messages == nil
  end
end
