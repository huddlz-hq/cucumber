defmodule Cucumber.StepError do
  @moduledoc """
  Exception raised when a step in a Cucumber scenario fails.

  This module provides detailed error reporting for two main failure cases:

  1. A step has no matching step definition
  2. A step's implementation raises an error or returns `{:error, reason}`

  The error messages include helpful context like:
  - The failing step text and location
  - The scenario name and feature file
  - A history of previously executed steps
  - Suggestions for implementing missing steps
  """

  defexception [
    :message,
    :step,
    :pattern,
    :feature_file,
    :scenario_name,
    :failure_reason,
    :step_history
  ]

  @type t :: %__MODULE__{
          message: String.t(),
          step: Gherkin.Step.t() | nil,
          pattern: String.t() | nil,
          feature_file: String.t() | nil,
          scenario_name: String.t() | nil,
          failure_reason: term(),
          step_history: list()
        }

  @doc false
  def undefined(step, context) do
    missing_error(
      step,
      Map.get(context, :feature_file, "unknown"),
      Map.get(context, :scenario_name, "unknown scenario"),
      recent_history(context),
      Map.get(context, :scenario_line)
    )
  end

  @doc false
  def execution_failure(context, step, pattern, {kind, reason, trace}, attachments) do
    step
    |> execution_error(
      pattern,
      describe_failure(kind, reason, trace),
      Map.get(context, :feature_file, "unknown"),
      Map.get(context, :scenario_name, "unknown scenario"),
      recent_history(context),
      Map.get(context, :scenario_line)
    )
    |> append_attachments(attachments, context)
  end

  defp recent_history(context) do
    # The runtime appends the current step before execution. Only that final
    # entry failed, even when a previous step has the same text and location.
    case context |> Map.get(:step_history, []) |> Enum.take(-10) |> List.pop_at(-1) do
      {nil, []} -> []
      {failed, earlier} -> Enum.map(earlier, &{:passed, &1}) ++ [{:failed, failed}]
    end
  end

  @doc """
  Creates a new step error for a missing step definition.

  When a step in a feature file doesn't match any step definition, this function
  creates a helpful error message that includes a suggestion for implementing
  the missing step.

  ## Parameters

  * `step` - The `Gherkin.Step` struct that has no matching definition
  * `feature_file` - The path to the feature file containing the step
  * `scenario_name` - The name of the scenario containing the step
  * `step_history` - A list of previously executed steps with their status

  ## Returns

  Returns a `Cucumber.StepError` struct with a formatted error message and context.

  ## Examples

  The error message will include a suggested implementation like:

      step "I click the submit button", context do
        # Your step implementation here
        context
      end
  """
  @spec missing_step_definition(Gherkin.Step.t(), String.t(), String.t(), list()) :: t()
  def missing_step_definition(step, feature_file, scenario_name, step_history \\ []) do
    missing_error(
      step,
      feature_file,
      scenario_name,
      step_history,
      extract_scenario_line(step_history)
    )
  end

  defp missing_error(step, feature_file, scenario_name, step_history, scenario_line) do
    location = location(feature_file, scenario_line, step)

    message = """
    No matching step definition found for step:

      #{step.keyword} #{step.text}

    in scenario "#{scenario_name}" (#{location})

    Please define this step with:

    step "#{format_step_for_suggestion(step.text)}", context do
      # Your step implementation here
      context
    end
    """

    %__MODULE__{
      message: message,
      step: step,
      feature_file: feature_file,
      scenario_name: scenario_name,
      failure_reason: :missing_step_definition,
      step_history: step_history
    }
  end

  @doc """
  Creates a new step error for a step execution failure.

  When a step implementation raises an exception or returns `{:error, reason}`,
  this function creates a detailed error message with context about the failure.

  ## Parameters

  * `step` - The `Gherkin.Step` struct that failed during execution
  * `pattern` - The step pattern that matched the step
  * `failure_reason` - The exception or error reason
  * `feature_file` - The path to the feature file containing the step
  * `scenario_name` - The name of the scenario containing the step
  * `step_history` - A list of previously executed steps with their status

  ## Returns

  Returns a `Cucumber.StepError` struct with a formatted error message and context.

  ## Examples

  The error message will include details like:

      Step failed:

        Then the result should be 10

      in scenario "Basic math" (test/features/calculator.feature:12)
      matching pattern: "the result should be {int}"

      Expected 10 but got 9

      Step execution history:
        [passed] Given I have entered 5 into the calculator
        [passed] And I have entered 4 into the calculator
        [passed] When I press add
        [failed] Then the result should be 10
  """
  @spec failed_step(Gherkin.Step.t(), String.t(), term(), String.t(), String.t(), list()) :: t()
  def failed_step(step, pattern, failure_reason, feature_file, scenario_name, step_history \\ []) do
    execution_error(
      step,
      pattern,
      failure_reason,
      feature_file,
      scenario_name,
      step_history,
      extract_scenario_line(step_history)
    )
  end

  defp execution_error(
         step,
         pattern,
         failure_reason,
         feature_file,
         scenario_name,
         step_history,
         scenario_line
       ) do
    location = location(feature_file, scenario_line, step)

    message = """
    Step failed:

      #{step.keyword} #{step.text}

    in scenario "#{scenario_name}" (#{location})
    matching pattern: "#{pattern}"

    #{format_failure_reason(failure_reason)}
    """

    formatted_message =
      if step_history != nil and step_history != [] do
        message <> "\n" <> format_step_history(step_history)
      else
        message
      end

    %__MODULE__{
      message: formatted_message,
      step: step,
      pattern: pattern,
      feature_file: feature_file,
      scenario_name: scenario_name,
      failure_reason: failure_reason,
      step_history: step_history
    }
  end

  defp location(file, line, _step) when is_integer(line) and line > 0, do: "#{file}:#{line}"
  defp location(file, _line, step), do: "#{file}:#{step.line + 1}"

  defp format_step_for_suggestion(text) do
    # Simple conversion to use Cucumber Expression placeholders
    # Replace quoted strings with {string}, numbers with {int} or {float}
    text
    |> String.replace(~r/"([^"]*)"/, "{string}")
    |> String.replace(~r/\b(\d+\.\d+)\b/, "{float}")
    |> String.replace(~r/\b(\d+)\b/, "{int}")
  end

  defp format_failure_reason(reason) when is_binary(reason) do
    # For multi-line reasons, ensure proper formatting
    if String.contains?(reason, "\n") do
      format_multiline_reason(reason)
    else
      reason
    end
  end

  defp format_failure_reason(%{message: message}), do: format_failure_reason(message)

  defp format_failure_reason(%{__exception__: true} = exception),
    do: format_failure_reason(Exception.message(exception))

  defp format_failure_reason(reason), do: inspect(reason, pretty: true)

  defp format_multiline_reason(reason) do
    reason
    |> String.split("\n")
    |> Enum.map_join("\n", &format_line/1)
  end

  defp format_line(line) do
    if String.trim(line) == "", do: "", else: line
  end

  defp format_step_history(step_history) do
    """
    Step execution history:
    #{Enum.map_join(step_history, "\n", &format_step_history_item/1)}
    """
  end

  defp format_step_history_item({status, step, _context}),
    do: format_step_history_item({status, step})

  defp format_step_history_item({status, step}) do
    "  [#{status}] #{step.keyword} #{step.text}"
  end

  defp extract_scenario_line(step_history) when is_list(step_history) do
    # Step history might have the scenario line in the context
    case step_history do
      [{_, _, context} | _] when is_map(context) ->
        Map.get(context, :scenario_line)

      _ ->
        nil
    end
  end

  defp extract_scenario_line(_), do: nil

  defp describe_failure(:error, reason, stacktrace) do
    format_exception_for_display(Exception.normalize(:error, reason, stacktrace))
  end

  # Exits and throws: the banner names the original kind and reason
  # (e.g. `** (exit) :timeout`)
  defp describe_failure(kind, reason, _stacktrace) do
    Exception.format_banner(kind, reason)
  end

  defp append_attachments(error, attachments, context) do
    scenario_attachments =
      Enum.filter(attachments, fn attachment ->
        attachment.feature_file == Map.get(context, :feature_file) and
          attachment.scenario_name == Map.get(context, :scenario_name) and
          attachment.attempt == Map.get(context, :retry_attempt)
      end)

    case scenario_attachments do
      [] ->
        error

      attachments ->
        listing = Enum.map_join(attachments, "\n", &format_attachment/1)
        %{error | message: error.message <> "\n\nAttachments:\n\n" <> listing <> "\n"}
    end
  end

  defp format_attachment(%Cucumber.Attachment{} = attachment) do
    name = if attachment.filename, do: " (#{attachment.filename})", else: ""

    body =
      case attachment.encoding do
        :base64 -> "#{byte_size(Base.decode64!(attachment.body))} bytes, base64-encoded"
        :identity -> truncate(attachment.body, 200)
      end

    "  * #{attachment.media_type}#{name}: #{body}"
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp format_exception_for_display(exception) do
    # Format the exception with enhanced readability
    case exception do
      %ExUnit.AssertionError{} = e ->
        format_assertion_error(e)

      %{__struct__: module} = e ->
        if assertion_error_module?(module),
          do: format_assertion_error(e),
          else: Exception.message(e)

      other ->
        inspect(other, pretty: true)
    end
  end

  defp assertion_error_module?(module) do
    module_str = Atom.to_string(module)
    String.ends_with?(module_str, "AssertionError") and Code.ensure_loaded?(module)
  end

  defp format_assertion_error(error) do
    # Extract the most useful parts of assertion errors
    base_message = Exception.message(error)

    # For PhoenixTest errors, enhance the formatting
    if String.contains?(base_message, "Found these elements") do
      lines = String.split(base_message, "\n")

      # Find where HTML elements start
      {before_html, html_and_after} =
        Enum.split_while(lines, fn line ->
          not (String.trim(line) |> String.starts_with?("<"))
        end)

      # Format the message parts
      formatted_before = Enum.join(before_html, "\n")

      # Group and format HTML elements
      formatted_html =
        html_and_after
        |> format_html_elements()
        |> Enum.join("\n")

      formatted_before <> "\n" <> formatted_html
    else
      base_message
    end
  end

  defp format_html_elements(lines) do
    lines
    |> group_html_elements()
    |> Enum.map(&format_single_html_element/1)
    |> Enum.reject(&(&1 == []))
  end

  defp group_html_elements(lines) do
    lines
    |> Enum.reduce({[], []}, &group_line/2)
    |> finalize_groups()
  end

  defp group_line(line, {groups, current}) do
    if html_line?(line) do
      {groups, current ++ [line]}
    else
      finalize_current_group(groups, current)
    end
  end

  defp finalize_current_group(groups, []), do: {groups, []}
  defp finalize_current_group(groups, current), do: {groups ++ [current], []}

  defp finalize_groups({groups, []}), do: groups
  defp finalize_groups({groups, current}), do: groups ++ [current]

  defp html_line?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "<") or String.ends_with?(trimmed, ">")
  end

  defp format_single_html_element(lines) do
    # Format a single HTML element with proper indentation
    lines
    |> Enum.map_join("\n", fn line ->
      "  " <> line
    end)
    # Add blank line after each element
    |> then(&[&1, ""])
  end
end
