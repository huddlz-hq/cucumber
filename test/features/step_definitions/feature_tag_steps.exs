defmodule FeatureTagSteps do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step "the database is initialized", context do
    # This should have database setup from feature-level @database hook
    assert Map.has_key?(context, :database_ready),
           "Database should be ready from feature-level hook"

    {:ok, context}
  end

  step "I query the database", context do
    assert context.database_ready, "Database should still be ready"
    {:ok, Map.put(context, :query_result, "data")}
  end

  step "I should get results", context do
    assert context.query_result == "data"
    {:ok, context}
  end

  step "I query the database with special permissions", context do
    assert context.database_ready, "Database should be ready"

    assert Map.has_key?(context, :special_permissions),
           "Special permissions should be set from @special hook"

    {:ok, Map.put(context, :query_result, "special_data")}
  end

  step "I should get special results", context do
    assert context.query_result == "special_data"
    {:ok, context}
  end
end
