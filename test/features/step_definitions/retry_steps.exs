defmodule RetrySteps do
  use Cucumber.StepDefinition

  step "a flaky step that passes on the second attempt", context do
    # Retry attempts run sequentially in the same test process, so the
    # process dictionary counts attempts and resets naturally per test run
    attempts = Process.get(:flaky_step_attempts, 0) + 1
    Process.put(:flaky_step_attempts, attempts)

    if attempts < 2 do
      raise "flaky! (deliberate first-attempt failure, attempt #{context.retry_attempt})"
    end

    :ok
  end
end
