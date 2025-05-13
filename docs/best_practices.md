# Best Practices for Cucumber Tests

This guide outlines best practices for writing and organizing your Cucumber tests to ensure they remain maintainable, readable, and effective.

## Feature File Organization

### Directory Structure

```
test/
├── features/           # Feature files
│   ├── authentication/ # Feature grouping by domain
│   │   ├── login.feature
│   │   └── registration.feature
│   └── shopping/       # Another domain
│       ├── cart.feature
│       └── checkout.feature
└── lib/                # Test modules with step definitions
    ├── authentication_test.exs
    └── shopping_test.exs
```

### Naming Conventions

- Use snake_case for feature file names
- Group related features into subdirectories
- Name test modules with a descriptive suffix (e.g., `LoginTest`, `CheckoutTest`)

## Writing Good Scenarios

### Scenario Best Practices

1. **Keep scenarios focused**: Each scenario should test one specific behavior
2. **Be consistent**: Use consistent language across scenarios
3. **Use concrete examples**: Prefer specific, realistic values to abstract placeholders
4. **Avoid technical details**: Keep scenarios in business language
5. **Keep them short**: Aim for 3-7 steps per scenario
6. **Use backgrounds wisely**: Only for truly common setup steps

### Example: Bad vs. Good

Bad:
```gherkin
Scenario: User interaction
  Given a user
  When the user does stuff
  Then the outcome is good
```

Good:
```gherkin
Scenario: Customer adds product to cart from product detail page
  Given I am logged in as "john@example.com"
  And I am viewing the product "Ergonomic Keyboard"
  When I click the "Add to Cart" button
  Then I should see "Product added to cart" message
  And my cart should contain 1 item
```

## Step Definition Best Practices

### Organization

1. **Group related step definitions**: Keep related steps together in the same file
2. **Use helper functions**: Extract common functionality into helper functions
3. **Create reusable steps**: Design steps to be reused across scenarios

### Naming Steps

1. **Use the actor's perspective**: "I click the button" rather than "Button is clicked"
2. **Be specific**: "I submit the registration form" rather than "I submit the form"
3. **Avoid technical implementation details**: "I click Login" rather than "I click #login-button"

### Step Implementation

```elixir
# Good: Clear, focused, with good error messages
defstep "I click the {string} button", context do
  button_text = List.first(context.args)
  
  case find_button(button_text) do
    {:ok, button} -> 
      click(button)
      :ok
    {:error, :not_found} ->
      {:error, "Button with text '#{button_text}' not found on page"}
  end
end

# Bad: Vague, doing too much, poor error handling
defstep "I interact with the page", _context do
  find_element("#some-button") |> click()
  :ok
end
```

## Context Management

### Passing Data Between Steps

```elixir
# First step establishes context
defstep "I submit an order for {string}", _context do
  product_name = List.first(context.args)
  order_id = create_order(product_name)
  
  # Return context to be used in following steps
  {:ok, %{product_name: product_name, order_id: order_id}}
end

# Second step uses that context
defstep "I should receive an order confirmation email", context do
  # Access data from previous step
  assert_email_sent(
    to: context.user.email,
    subject: "Order Confirmation for ##{context.order_id}",
    containing: context.product_name
  )
  
  :ok
end
```

### Context Guidelines

1. **Be explicit**: Only store what's needed for subsequent steps
2. **Consider naming**: Use descriptive keys in the context map
3. **Clean up after yourself**: Don't let the context grow too large

## Testing Different Layers

### UI Testing

```elixir
defstep "I click the {string} button", context do
  button_text = List.first(context.args)
  click_button(button_text)
  :ok
end
```

### API Testing

```elixir
defstep "I make a GET request to {string}", context do
  endpoint = List.first(context.args)
  response = HTTPoison.get!("#{context.base_url}#{endpoint}")
  {:ok, Map.put(context, :response, response)}
end

defstep "the response status should be {int}", context do
  expected_status = List.first(context.args)
  assert context.response.status_code == expected_status
  :ok
end
```

### Database Testing

```elixir
defstep "there should be a user in the database with email {string}", context do
  email = List.first(context.args)
  user = Repo.get_by(User, email: email)
  assert user != nil
  :ok
end
```

## Handling Test Data

### Using Factory Functions

```elixir
# Helper function to create test data
defp create_test_user(attrs \\ %{}) do
  defaults = %{
    username: "testuser",
    email: "test@example.com",
    password: "password123"
  }
  
  Map.merge(defaults, attrs)
  |> User.changeset()
  |> Repo.insert!()
end

# Use in step definitions
defstep "a user exists with email {string}", context do
  email = List.first(context.args)
  user = create_test_user(%{email: email})
  {:ok, %{user: user}}
end
```

### Using Tags for Test Environment

```gherkin
@require_db_cleanup
Feature: User Management

Scenario: Create a new user
  When I create a user with email "newuser@example.com"
  Then the user should exist in the database
```

```elixir
setup context do
  if "require_db_cleanup" in context.feature_tags do
    on_exit(fn -> 
      # Clean up database after tests
      Repo.delete_all(User)
    end)
  end
  
  context
end
```

## Common Testing Patterns

### The Given-When-Then Formula

1. **Given**: Establishes the initial context
2. **When**: Describes the key action
3. **Then**: Specifies expected outcomes

### Table-Driven Scenarios

```gherkin
Scenario Outline: User registration with different passwords
  When I try to register with email "user@example.com" and password "<password>"
  Then registration should be "<result>"
  And I should see message "<message>"
  
  Examples:
    | password      | result    | message                            |
    | pass          | failed    | Password is too short              |
    | password123   | success   | Registration successful            |
    | noUppercase1  | failed    | Password needs an uppercase letter |
    | NoNumbers     | failed    | Password needs a number            |
```

### State-Based Testing

```gherkin
Scenario: Completed order cannot be modified
  Given I have an order with id "12345"
  And the order status is "completed"
  When I attempt to modify the order
  Then I should receive an error "Cannot modify completed order"
```

## Continuous Integration

### Running Tests in CI

```yaml
# Example GitHub Actions workflow
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: erlef/setup-beam@v1
        with:
          otp-version: '25'
          elixir-version: '1.14'
      - run: mix deps.get
      - run: mix test
```

### Reporting Test Results

Consider tools for generating test reports:

```elixir
# In test_helper.exs
ExUnit.configure(
  formatters: [ExUnit.CLIFormatter, JUnitFormatter]
)
```

## Advanced Techniques

### Custom Parameter Types

```elixir
# Custom parameter type for dates
defmodule DateParameterType do
  def match("today") do
    Date.utc_today()
  end
  
  def match("tomorrow") do
    Date.add(Date.utc_today(), 1)
  end
  
  def match(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> raise "Invalid date format: #{date_string}. Use ISO-8601 format."
    end
  end
end

# Using in step definitions
defstep "I schedule an appointment for {date}", context do
  date = List.first(context.args)
  # date is already a Date struct
  {:ok, %{appointment_date: date}}
end
```

### Sharing Steps Between Test Modules

```elixir
# In a shared module
defmodule CommonSteps do
  defmacro __using__(_opts) do
    quote do
      defstep "I am logged in as {string}", context do
        username = List.first(context.args)
        # Login logic
        {:ok, %{current_user: find_user(username)}}
      end
      
      defstep "I should be on the {string} page", context do
        page_name = List.first(context.args)
        assert current_page() == page_name
        :ok
      end
    end
  end
end

# In a test module
defmodule AuthenticationTest do
  use Cucumber, feature: "authentication.feature"
  use CommonSteps
  
  # Additional step definitions specific to this module
end
```

### Performance Considerations

1. **Minimize external dependencies**: Mock third-party services
2. **Optimize database usage**: Use transactions, clean up test data
3. **Reuse browser sessions**: For UI tests, avoid creating new sessions for each scenario
4. **Parallelization**: Consider running tests in parallel when possible