# Error Handling and Debugging

Cucumber for Elixir provides detailed error reporting to help debug test failures. This document explains how to handle and understand errors in your Cucumber tests.

## Types of Errors

### Missing Step Definition

When a step in your feature file has no matching definition, the framework will provide a helpful error message:

```
** (Cucumber.StepError) No matching step definition found for step:

  When I try to use a step with no definition

in scenario "Missing Step Example" (test/features/example.feature:6)

Please define this step with:

step "I try to use a step with no definition", context do
  # Your step implementation here
  context
end
```

This error not only tells you which step is missing, but also provides a template for implementing the missing step definition.

### Failed Step

When a step fails during execution (due to a failed assertion or an exception), you'll get an error like this:

```
** (Cucumber.StepError) Step failed:

  Then the validation should succeed

in scenario "Form Submission" (test/features/forms.feature:12)
matching pattern: "the validation should succeed"

Validation failed: invalid input data

Step execution history:
  [passed] Given a form to fill out
  [passed] When I submit invalid data
  [failed] Then the validation should succeed
```

The error message includes:
- Which step failed
- The scenario and file where the failure occurred
- The step pattern that matched
- The error message from the step implementation
- The execution history, showing which steps passed and which failed

### Syntax Errors in Feature Files

If there are syntax errors in your feature files, you'll get an error when the parser tries to process the file:

```
** (Cucumber.ParseError) Syntax error in feature file:

  test/features/invalid.feature:5

Expected a scenario or background but found:

  Invalid line that doesn't start with a Gherkin keyword
```

## Step Failure Handling

Step definitions can indicate failure in several ways:

### 1. Assertions

Using ExUnit assertions will cause the step to fail if the assertion fails:

```elixir
step "the total should be {float}", %{args: [total]} = context do
  assert context.cart_total == total
  :ok
end
```

### 2. Raising Exceptions

Any uncaught exception will cause the step to fail:

```elixir
step "I click the submit button", _context do
  raise "The submit button is disabled"
  :ok
end
```

### 3. Returning `{:error, reason}`

You can explicitly return an error tuple to fail a step:

```elixir
step "the payment should be successful", context do
  if context.payment_status == :success do
    :ok
  else
    {:error, "Expected payment to succeed, but got status: #{context.payment_status}"}
  end
end
```

## Debugging Tips

### 1. Use IO.inspect for Debug Output

Insert `IO.inspect` calls to see the values of variables during test execution:

```elixir
step "I should see my order summary", context do
  IO.inspect(context, label: "Context in order summary step")
  assert context.order != nil
  :ok
end
```

### 2. Add Step Execution Logs

Log information about step execution:

```elixir
step "I complete the checkout process", context do
  IO.puts("Starting checkout process")
  # Checkout logic
  IO.puts("Completed checkout process")
  :ok
end
```

### 3. Examine the Full Context

Print the full context at any point to see the accumulated state:

```elixir
step "I check my context", context do
  IO.inspect(context, label: "Current context", pretty: true)
  :ok
end
```

### 4. Create Debug-Only Steps

Add steps specifically for debugging:

```elixir
step "I debug my test state", context do
  IO.puts("==== DEBUG STATE ====")
  IO.inspect(context.current_page, label: "Current Page")
  IO.inspect(context.user, label: "Current User")
  IO.inspect(context.cart_items, label: "Cart Items")
  IO.puts("==== END DEBUG ====")
  :ok
end
```

## Handling Flaky Tests

Sometimes tests can be inconsistent due to timing issues, especially with UI interactions:

```elixir
step "I should see the confirmation message", context do
  # Add delay or retry logic for UI-related assertions
  :timer.sleep(500)  # Give the UI time to update
  assert_text("Your order has been confirmed")
  :ok
end
```

Consider implementing retry logic for flaky steps:

```elixir
defp retry_until(function, max_attempts \\ 5, delay \\ 100) do
  Enum.reduce_while(1..max_attempts, nil, fn attempt, _acc ->
    case function.() do
      {:ok, result} -> {:halt, {:ok, result}}
      {:error, reason} ->
        if attempt == max_attempts do
          {:halt, {:error, reason}}
        else
          :timer.sleep(delay)
          {:cont, nil}
        end
    end
  end)
end

step "I should see the success notification", _context do
  result = retry_until(fn ->
    if element_visible?(".success-notification") do
      {:ok, true}
    else
      {:error, "Success notification not visible"}
    end
  end)

  case result do
    {:ok, _} -> :ok
    {:error, reason} -> {:error, reason}
  end
end
```

## Common Error Patterns and Solutions

| Error Pattern | Possible Cause | Solution |
|---------------|----------------|----------|
| Step not found | Step definition missing or typo in step | Create the missing step definition or correct the typo |
| Assertion failure | Expected value doesn't match actual | Check your test data and application logic |
| Timeout | Asynchronous operation didn't complete in time | Increase timeout or add retry logic |
| Element not found | UI element not rendered yet or selector wrong | Add delay, retry, or correct the selector |
| Context key missing | Previous step didn't set expected data | Ensure required context keys are set in earlier steps |