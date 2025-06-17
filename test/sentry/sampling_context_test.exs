defmodule Sentry.Opentelemetry.SamplingContextTest do
  use Sentry.Case, async: true

  alias SamplingContext

  describe "Access functions" do
    test "fetch/2 returns {:ok, value} for existing keys" do
      transaction_context = %{
        name: "GET /users",
        op: "http.server",
        trace_id: 123,
        attributes: %{"http.method" => "GET"}
      }

      sampling_context = %SamplingContext{
        transaction_context: transaction_context,
        parent_sampled: true
      }

      assert {:ok, ^transaction_context} =
               SamplingContext.fetch(sampling_context, :transaction_context)

      assert {:ok, true} = SamplingContext.fetch(sampling_context, :parent_sampled)
    end

    test "fetch/2 returns :error for non-existing keys" do
      sampling_context = %SamplingContext{
        transaction_context: %{name: "test", op: "test", trace_id: 123, attributes: %{}},
        parent_sampled: nil
      }

      assert :error = SamplingContext.fetch(sampling_context, :non_existing_key)
      assert :error = SamplingContext.fetch(sampling_context, :invalid)
    end

    test "get_and_update/3 updates existing keys" do
      transaction_context = %{
        name: "GET /users",
        op: "http.server",
        trace_id: 123,
        attributes: %{"http.method" => "GET"}
      }

      sampling_context = %SamplingContext{
        transaction_context: transaction_context,
        parent_sampled: false
      }

      update_fun = fn current_value ->
        {current_value, !current_value}
      end

      {old_value, updated_context} =
        SamplingContext.get_and_update(sampling_context, :parent_sampled, update_fun)

      assert old_value == false
      assert updated_context.parent_sampled == true
      assert updated_context.transaction_context == transaction_context
    end

    test "get_and_update/3 handles :pop operation" do
      sampling_context = %SamplingContext{
        transaction_context: %{name: "test", op: "test", trace_id: 123, attributes: %{}},
        parent_sampled: true
      }

      pop_fun = fn _current_value -> :pop end

      {old_value, updated_context} =
        SamplingContext.get_and_update(sampling_context, :parent_sampled, pop_fun)

      assert old_value == true
      refute Map.has_key?(updated_context, :parent_sampled)
    end

    test "get_and_update/3 works with non-existing keys" do
      sampling_context = %SamplingContext{
        transaction_context: %{name: "test", op: "test", trace_id: 123, attributes: %{}},
        parent_sampled: nil
      }

      update_fun = fn current_value ->
        {current_value, "new_value"}
      end

      {old_value, updated_context} =
        SamplingContext.get_and_update(sampling_context, :new_key, update_fun)

      assert old_value == nil
      assert Map.get(updated_context, :new_key) == "new_value"
    end

    test "pop/2 removes existing keys and returns value" do
      transaction_context = %{
        name: "POST /api",
        op: "http.server",
        trace_id: 456,
        attributes: %{"http.method" => "POST"}
      }

      sampling_context = %SamplingContext{
        transaction_context: transaction_context,
        parent_sampled: true
      }

      {popped_value, updated_context} = SamplingContext.pop(sampling_context, :parent_sampled)

      assert popped_value == true
      refute Map.has_key?(updated_context, :parent_sampled)
      assert updated_context.transaction_context == transaction_context
    end

    test "pop/2 returns nil for non-existing keys" do
      sampling_context = %SamplingContext{
        transaction_context: %{name: "test", op: "test", trace_id: 123, attributes: %{}},
        parent_sampled: nil
      }

      {popped_value, updated_context} = SamplingContext.pop(sampling_context, :non_existing_key)

      assert popped_value == nil
      assert updated_context == sampling_context
    end

    test "Access behavior works with bracket notation" do
      transaction_context = %{
        name: "DELETE /resource",
        op: "http.server",
        trace_id: 789,
        attributes: %{"http.method" => "DELETE"}
      }

      sampling_context = %SamplingContext{
        transaction_context: transaction_context,
        parent_sampled: false
      }

      # Test bracket access for reading
      assert sampling_context[:transaction_context] == transaction_context
      assert sampling_context[:parent_sampled] == false
      assert sampling_context[:non_existing] == nil

      # Test get_in/2
      assert get_in(sampling_context, [:transaction_context, :name]) == "DELETE /resource"

      assert get_in(sampling_context, [:transaction_context, :attributes, "http.method"]) ==
               "DELETE"
    end

    test "Access behavior works with put_in/3" do
      sampling_context = %SamplingContext{
        transaction_context: %{name: "test", op: "test", trace_id: 123, attributes: %{}},
        parent_sampled: nil
      }

      updated_context = put_in(sampling_context[:parent_sampled], true)

      assert updated_context.parent_sampled == true
      assert updated_context.transaction_context == sampling_context.transaction_context
    end

    test "Access behavior works with update_in/3" do
      transaction_context = %{
        name: "PUT /update",
        op: "http.server",
        trace_id: 999,
        attributes: %{"http.method" => "PUT", "http.status_code" => 200}
      }

      sampling_context = %SamplingContext{
        transaction_context: transaction_context,
        parent_sampled: false
      }

      updated_context =
        update_in(sampling_context[:transaction_context][:attributes], fn attrs ->
          Map.put(attrs, "http.status_code", 404)
        end)

      assert get_in(updated_context, [:transaction_context, :attributes, "http.status_code"]) ==
               404

      assert get_in(updated_context, [:transaction_context, :attributes, "http.method"]) == "PUT"
      assert updated_context.parent_sampled == false
    end
  end
end
