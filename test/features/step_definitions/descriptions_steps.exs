defmodule DescriptionsSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "a noted base value {string}", %{args: [value]} do
    %{base_value: value}
  end

  step "I note this docstring:", context do
    assert context.base_value == "carrot"
    %{noted: context.docstring, noted_media: Map.get(context, :docstring_media_type)}
  end

  step "the noted docstring is {string}", %{args: [expected]} = context do
    assert context.noted == expected
    :ok
  end

  step "the noted docstring contains {string}", %{args: [expected]} = context do
    assert context.noted =~ expected
    :ok
  end

  step "the noted docstring has no media type", context do
    assert context.noted_media == nil
    :ok
  end

  step "the noted docstring media type is {string}", %{args: [expected]} = context do
    assert context.noted_media == expected
    :ok
  end

  step "I note the word {word}", %{args: [word]} do
    %{word: word}
  end

  step "the noted word is {string}", %{args: [expected]} = context do
    assert context.word == expected
    :ok
  end
end
