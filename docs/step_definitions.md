# Step Definitions

Step definitions connect the Gherkin steps in your feature files to actual code. They're the glue between your natural language specifications and the implementation that tests your application.

## Basic Step Definition

Step definitions are created using the `defstep` macro:

```elixir
defstep "I am logged in as a customer", context do
  # Authentication logic here
  {:ok, %{user: create_and_login_customer()}}
end
```

## Steps with Parameters

Cucumber supports several parameter types that can be used in step patterns:

### String Parameters

```elixir
defstep "I am on the product page for {string}", context do
  product_name = List.first(context.args)
  # Navigate to product page
  {:ok, %{current_page: :product, product_name: product_name}}
end
```

### Integer Parameters

```elixir
defstep "I should have {int} items in my wishlist", context do
  expected_count = List.first(context.args)
  # Assertion for wishlist count
  assert get_wishlist_count() == expected_count
  :ok
end
```

### Float Parameters

```elixir
defstep "the total price should be {float}", context do
  expected_total = List.first(context.args)
  # Assertion for price
  assert_in_delta get_cart_total(), expected_total, 0.01
  :ok
end
```

### Word Parameters

```elixir
defstep "I should see the {word} dashboard", context do
  dashboard_type = List.first(context.args)
  # Assertion for dashboard type
  assert get_current_dashboard() == dashboard_type
  :ok
end
```

## Working with Data Tables

In your feature file:
```gherkin
Given I have the following items in my cart:
  | Product Name    | Quantity | Price |
  | Smartphone      | 1        | 699.99|
  | Protection Plan | 1        | 79.99 |
```

In your test module:
```elixir
defstep "I have the following items in my cart:", context do
  # Access the datatable
  datatable = context.datatable

  # Access headers
  headers = datatable.headers  # ["Product Name", "Quantity", "Price"]
  
  # Access rows as maps
  items = datatable.maps
  # [
  #   %{"Product Name" => "Smartphone", "Quantity" => "1", "Price" => "699.99"},
  #   %{"Product Name" => "Protection Plan", "Quantity" => "1", "Price" => "79.99"}
  # ]
  
  # Process the items
  {:ok, %{cart_items: items}}
end
```

## Working with Doc Strings

In your feature file:
```gherkin
When I submit the following feedback:
  """
  I really like your product, but I think
  it could be improved by adding more features.
  Keep up the good work!
  """
```

In your test module:
```elixir
defstep "I submit the following feedback:", context do
  feedback_text = context.docstring
  # Submit feedback logic
  {:ok, %{submitted_feedback: feedback_text}}
end
```

## Return Values

Step definitions can return values in several ways:

### 1. Return `:ok`

For steps that perform actions but don't need to update context:

```elixir
defstep "I click the submit button", _context do
  # Click logic
  :ok
end
```

### 2. Return a Map

To directly replace the context:

```elixir
defstep "I am on the home page", _context do
  %{current_page: :home}
end
```

### 3. Return `{:ok, map}`

To merge new values into the context:

```elixir
defstep "I search for {string}", context do
  search_term = List.first(context.args)
  # Search logic
  {:ok, %{search_term: search_term, search_results: perform_search(search_term)}}
end
```

### 4. Return `{:error, reason}`

To indicate a step failure with a reason:

```elixir
defstep "the payment should be successful", context do
  if context.payment_status == :success do
    :ok
  else
    {:error, "Expected payment to succeed, but got status: #{context.payment_status}"}
  end
end
```

## Step Patterns and Matching

When a Gherkin step needs to be executed, the framework searches through all step definitions for a matching pattern. The matching process:

1. Starts with the current module's step definitions
2. Looks for an exact match first
3. Then tries to match using parameter placeholders
4. Raises an error if no matching step definition is found

## Context Management

The context object is a map that flows from step to step during a scenario's execution:

- It starts as an empty map or the ExUnit test context
- Each step can add to, modify, or replace the context
- Any values added to the context are available to subsequent steps
- It's useful for sharing state between steps, such as user sessions, form data, etc.

Example of context flow:

```elixir
defstep "I am on the login page", _context do
  # Initial step sets up the page
  %{page: :login}
end

defstep "I enter my credentials", context do
  # Second step uses the page from previous step and adds credentials
  assert context.page == :login
  {:ok, %{username: "testuser", password: "password123"}}
end

defstep "I click the login button", context do
  # Third step can access all previous context values
  assert context.page == :login
  assert context.username == "testuser" 
  assert context.password == "password123"
  
  # And add more context values
  {:ok, %{logged_in: true, user_id: 123}}
end
```

## Best Practices for Step Definitions

1. **Keep steps reusable** - Write generic steps that can be used across features
2. **One assertion per step** - Especially for "Then" steps
3. **Use context for state management** - Pass necessary data between steps
4. **Handle errors gracefully** - Provide helpful error messages
5. **Name steps from the user's perspective** - Focus on what, not how
6. **Organize steps logically** - Group related steps together
7. **Document complex steps** - Add comments for steps with complex logic
8. **Avoid implementation details in step patterns** - Keep to business terminology