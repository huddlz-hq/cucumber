defmodule Cucumber.CckApproval.Definitions do
  @moduledoc """
  Elixir translations of the CCK samples' reference TypeScript step
  definitions, hooks, and parameter types (`<sample>.ts` in the kit),
  used by the approval tests in `test/cucumber/cck_approval_test.exs`.

  Each nested module mirrors one sample's definition file as closely as
  the two languages allow: same patterns, same behavior, same failure
  messages. Do not add test instrumentation here — the approval
  comparison depends on these producing exactly the reference behavior.
  """

  defmodule Minimal do
    @moduledoc false
    use Cucumber.StepDefinition

    step "I have {int} cukes in my belly", _context do
      :ok
    end
  end

  defmodule Cdata do
    @moduledoc false
    use Cucumber.StepDefinition

    step "I have {int} <![CDATA[cukes]]> in my belly", _context do
      :ok
    end
  end

  defmodule DataTables do
    @moduledoc false
    use Cucumber.StepDefinition
    import ExUnit.Assertions

    step "the following table is transposed:", context do
      transposed =
        context.datatable.raw
        |> Enum.zip()
        |> Enum.map(&Tuple.to_list/1)

      %{transposed: transposed}
    end

    step "it should be:", context do
      assert context.transposed == context.datatable.raw
      :ok
    end
  end

  defmodule Backgrounds do
    @moduledoc false
    use Cucumber.StepDefinition

    step "an order for {string}", _context do
      :ok
    end

    step "an action", _context do
      :ok
    end

    step "an outcome", _context do
      :ok
    end
  end

  defmodule DocStrings do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a doc string:", _context do
      :ok
    end
  end

  defmodule ExamplesTables do
    @moduledoc false
    use Cucumber.StepDefinition
    import ExUnit.Assertions

    step "there are {int} cucumbers", %{args: [count]} do
      %{count: count}
    end

    step "there are {int} friends", %{args: [friends]} do
      %{friends: friends}
    end

    step "I eat {int} cucumbers", %{args: [eat]} = context do
      %{count: context.count - eat}
    end

    step "I should have {int} cucumbers", %{args: [expected]} = context do
      assert context.count == expected
      :ok
    end

    step "each person can eat {int} cucumbers", %{args: [expected]} = context do
      assert div(context.count, 1 + context.friends) == expected
      :ok
    end
  end

  defmodule UnusedSteps do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a step that is used", _context do
      :ok
    end

    step "a step that is not used", _context do
      :ok
    end
  end

  defmodule StackTraces do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a step throws an exception", _context do
      raise "BOOM"
    end
  end

  defmodule Undefined do
    @moduledoc false
    use Cucumber.StepDefinition

    step "an implemented step", _context do
      :ok
    end

    step "a step that will be skipped", _context do
      :ok
    end
  end

  defmodule Ambiguous do
    @moduledoc false
    use Cucumber.StepDefinition

    step ~r/^a (.*?) with (.*?)$/, _context do
      # first one
      :ok
    end

    step ~r/^a step with (.*?)$/, _context do
      # second one
      :ok
    end
  end

  defmodule Pending do
    @moduledoc false
    use Cucumber.StepDefinition

    step "an implemented non-pending step", _context do
      :ok
    end

    step "an implemented step that is skipped", _context do
      :ok
    end

    step "an unimplemented pending step", _context do
      :pending
    end
  end

  defmodule Skipped do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a step that does not skip", _context do
      :ok
    end

    step "a step that is skipped", _context do
      :ok
    end

    step "I skip a step", _context do
      :skipped
    end
  end

  defmodule AllStatuses do
    @moduledoc false
    use Cucumber.StepDefinition

    step ~r/^a step$/, _context do
      :ok
    end

    step ~r/^a failing step$/, _context do
      raise "whoops"
    end

    step ~r/^a pending step$/, _context do
      :pending
    end

    step ~r/^a skipped step$/, _context do
      :skipped
    end

    step ~r/^an ambiguous (.*?)$/, _context do
      :ok
    end

    step ~r/^(.*?) ambiguous step$/, _context do
      :ok
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a step passes", _context do
      :ok
    end

    step "a step fails", _context do
      raise "Exception in step"
    end
  end

  defmodule HooksHooks do
    @moduledoc false
    use Cucumber.Hooks

    before_scenario _context do
      :ok
    end

    after_scenario _context do
      :ok
    end
  end

  defmodule PassingStep do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a step passes", _context do
      :ok
    end
  end

  defmodule HooksConditionalHooks do
    @moduledoc false
    use Cucumber.Hooks

    before_scenario "@passing-hook", _context do
      :ok
    end

    before_scenario "@fail-before", _context do
      raise "Exception in conditional hook"
    end

    after_scenario "@fail-after", _context do
      raise "Exception in conditional hook"
    end

    after_scenario "@passing-hook", _context do
      :ok
    end
  end

  defmodule HooksNamedHooks do
    @moduledoc false
    use Cucumber.Hooks

    before_scenario _context, name: "A named before hook" do
      :ok
    end

    after_scenario _context, name: "A named after hook" do
      :ok
    end
  end

  defmodule HooksSkipped do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a normal step", _context do
      :ok
    end

    step "a step that skips", _context do
      :skipped
    end
  end

  # A module rejects duplicate unnamed hooks, and `name:` would show up in
  # the hook envelopes (the reference's are unnamed) — so samples with
  # several identical hooks split them across modules, one per registration,
  # preserving the reference's registration order.
  defmodule HooksSkippedHooks1 do
    @moduledoc false
    use Cucumber.Hooks

    before_scenario _context do
      :ok
    end

    after_scenario _context do
      :ok
    end
  end

  defmodule HooksSkippedHooks2 do
    @moduledoc false
    use Cucumber.Hooks

    before_scenario "@skip-before", _context do
      :skipped
    end

    after_scenario "@skip-after", _context do
      :skipped
    end
  end

  defmodule HooksSkippedHooks3 do
    @moduledoc false
    use Cucumber.Hooks

    before_scenario _context do
      :ok
    end

    after_scenario _context do
      :ok
    end
  end

  defmodule SkippedFailingHook do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a step that skips", _context do
      :skipped
    end
  end

  defmodule SkippedFailingHookHooks do
    @moduledoc false
    use Cucumber.Hooks

    after_scenario _context do
      raise "whoops"
    end
  end

  defmodule GlobalHooks do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a step passes", _context do
      :ok
    end

    step "a step fails", _context do
      raise "Exception in step"
    end
  end

  defmodule GlobalHooksHooks1 do
    @moduledoc false
    use Cucumber.Hooks

    before_all _context do
      :ok
    end

    after_all _context do
      :ok
    end
  end

  defmodule GlobalHooksHooks2 do
    @moduledoc false
    use Cucumber.Hooks

    before_all _context do
      :ok
    end

    after_all _context do
      :ok
    end
  end

  defmodule GlobalHooksErrorSteps do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a step passes", _context do
      :ok
    end
  end

  defmodule ExplodingBeforeAllHooks do
    @moduledoc false
    use Cucumber.Hooks

    before_all _context do
      raise "BeforeAll hook went wrong"
    end

    after_all _context do
      :ok
    end
  end

  defmodule TrailingBeforeAllHooks do
    @moduledoc false
    use Cucumber.Hooks

    before_all _context do
      :ok
    end
  end

  defmodule ExplodingAfterAllHooks do
    @moduledoc false
    use Cucumber.Hooks

    before_all _context do
      :ok
    end

    after_all _context do
      raise "AfterAll hook went wrong"
    end
  end

  defmodule TrailingAfterAllHooks do
    @moduledoc false
    use Cucumber.Hooks

    after_all _context do
      :ok
    end
  end

  defmodule ParameterTypesSteps do
    @moduledoc false
    use Cucumber.StepDefinition
    import ExUnit.Assertions

    step "{flight} has been delayed", %{args: [flight]} do
      assert flight.from == "LHR"
      assert flight.to == "CDG"
      :ok
    end
  end

  defmodule ParameterTypesTypes do
    @moduledoc false
    use Cucumber.ParameterTypes

    parameter_type(:flight,
      regexp: ~r/([A-Z]{3})-([A-Z]{3})/,
      transform: fn from, to -> %{from: from, to: to} end
    )
  end

  defmodule RegularExpression do
    @moduledoc false
    use Cucumber.StepDefinition

    step ~r/^a (.*?)(?: and a (.*?))?(?: and a (.*?))?$/, _context do
      :ok
    end
  end

  defmodule Retry do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a step that always passes", _context do
      :ok
    end

    # The reference uses module-global attempt counters; `retry_attempt`
    # (1-based) expresses the same "fails until the Nth run" behavior.
    step "a step that passes the second time", context do
      if context.retry_attempt < 2, do: raise("Exception in step"), else: :ok
    end

    step "a step that passes the third time", context do
      if context.retry_attempt < 3, do: raise("Exception in step"), else: :ok
    end

    step "a step that always fails", _context do
      raise "Exception in step"
    end
  end

  defmodule RetryAmbiguous do
    @moduledoc false
    use Cucumber.StepDefinition

    # The reference registers the same cucumber expression twice; this
    # implementation rejects exact duplicates at discovery, so the
    # equivalent runtime ambiguity comes from two overlapping patterns.
    step "an ambiguous step", _context do
      :ok
    end

    step ~r/^an ambiguous step$/, _context do
      :ok
    end
  end

  defmodule RetryPending do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a pending step", _context do
      :pending
    end
  end

  defmodule Rules do
    @moduledoc false
    use Cucumber.StepDefinition
    import ExUnit.Assertions

    step "the customer has {int} cents", %{args: [money]} do
      %{money: money}
    end

    step "there are chocolate bars in stock", _context do
      %{stock: ["Mars"]}
    end

    step "there are no chocolate bars in stock", _context do
      %{stock: []}
    end

    step "the customer tries to buy a {int} cent chocolate bar", %{args: [price]} = context do
      if context.money >= price do
        %{chocolate: List.first(context.stock)}
      else
        :ok
      end
    end

    step "the sale should not happen", context do
      assert Map.get(context, :chocolate) == nil
      :ok
    end

    step "the sale should happen", context do
      assert context.chocolate
      :ok
    end
  end

  defmodule MultipleFeatures do
    @moduledoc false
    use Cucumber.StepDefinition

    step "an order for {string}", _context do
      :ok
    end
  end

  defmodule ExamplesTablesUndefined do
    @moduledoc false
    use Cucumber.StepDefinition
    import ExUnit.Assertions

    step "there are {int} cucumbers", %{args: [count]} do
      %{count: count}
    end

    step "I eat {int} cucumbers", %{args: [eat]} = context do
      %{count: context.count - eat}
    end

    step "I should have {int} cucumbers", %{args: [expected]} = context do
      assert context.count == expected
      :ok
    end
  end

  defmodule ExamplesTablesAttachment do
    @moduledoc false
    use Cucumber.StepDefinition

    step "a JPEG image is attached", context do
      jpeg = File.read!("test/fixtures/cck/examples-tables-attachment/cucumber.jpeg")
      Cucumber.attach(context, {:bytes, jpeg}, "image/jpeg")
    end

    step "a PNG image is attached", context do
      png = File.read!("test/fixtures/cck/examples-tables-attachment/cucumber.png")
      Cucumber.attach(context, {:bytes, png}, "image/png")
    end
  end

  defmodule AttachingScenarioHooks do
    @moduledoc false
    use Cucumber.Hooks

    before_scenario context do
      svg = File.read!("test/fixtures/cck/hooks-attachment/cucumber.svg")
      Cucumber.attach(context, {:bytes, svg}, "image/svg+xml")
    end

    after_scenario context do
      svg = File.read!("test/fixtures/cck/hooks-attachment/cucumber.svg")
      Cucumber.attach(context, {:bytes, svg}, "image/svg+xml")
    end
  end

  defmodule Attachments do
    @moduledoc false
    use Cucumber.StepDefinition

    step "the string {string} is attached as {string}", %{args: [text, media_type]} = context do
      Cucumber.attach(context, text, media_type)
    end

    step "the string {string} is logged", %{args: [text]} = context do
      Cucumber.log(context, text)
    end

    step "text with ANSI escapes is logged", context do
      Cucumber.log(
        context,
        "This displays a " <>
          "\e[31mr\e[0m\e[91ma\e[0m\e[33mi\e[0m\e[32mn\e[0m\e[34mb\e[0m\e[95mo\e[0m\e[35mw\e[0m"
      )
    end

    step "the following string is attached as {string}:", %{args: [media_type]} = context do
      Cucumber.attach(context, context.docstring, media_type)
    end

    step "an array with {int} bytes is attached as {string}",
         %{args: [size, media_type]} = context do
      bytes = :binary.list_to_bin(Enum.to_list(0..(size - 1)))
      Cucumber.attach(context, {:bytes, bytes}, media_type)
    end

    step "a PDF document is attached and renamed", context do
      pdf = File.read!("test/fixtures/cck/attachments/document.pdf")
      Cucumber.attach(context, {:bytes, pdf}, "application/pdf", filename: "renamed.pdf")
    end

    step "a link to {string} is attached", %{args: [uri]} = context do
      Cucumber.link(context, uri)
    end

    step "the string {string} is attached as {string} before a failure",
         %{args: [text, media_type]} = context do
      Cucumber.attach(context, text, media_type)
      raise "whoops"
    end
  end
end
