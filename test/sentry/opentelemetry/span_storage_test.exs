defmodule Sentry.OpenTelemetry.SpanStorageTest do
  use Sentry.Case, async: false

  alias Sentry.OpenTelemetry.{SpanStorage, SpanRecord}

  setup do
    if :ets.whereis(:span_storage) != :undefined do
      :ets.delete_all_objects(:span_storage)
    else
      start_supervised!(SpanStorage)
    end

    on_exit(fn ->
      if :ets.whereis(:span_storage) != :undefined do
        :ets.delete_all_objects(:span_storage)
      end
    end)

    :ok
  end

  describe "root spans" do
    test "stores and retrieves a root span" do
      root_span = %SpanRecord{
        span_id: "abc123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span"
      }

      SpanStorage.store_span(root_span)

      assert ^root_span = SpanStorage.get_root_span("abc123")
    end

    test "updates an existing root span" do
      root_span = %SpanRecord{
        span_id: "abc123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span"
      }

      updated_root_span = %SpanRecord{
        span_id: "abc123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "updated_root_span"
      }

      SpanStorage.store_span(root_span)
      SpanStorage.update_span(updated_root_span)

      assert ^updated_root_span = SpanStorage.get_root_span("abc123")
    end

    test "removes a root span" do
      root_span = %SpanRecord{
        span_id: "abc123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span"
      }

      SpanStorage.store_span(root_span)
      assert root_span == SpanStorage.get_root_span("abc123")

      SpanStorage.remove_span("abc123")
      assert nil == SpanStorage.get_root_span("abc123")
    end

    test "removes root span and all its children" do
      root_span = %SpanRecord{
        span_id: "root123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span"
      }

      child_span1 = %SpanRecord{
        span_id: "child1",
        parent_span_id: "root123",
        trace_id: "trace123",
        name: "child_span_1"
      }

      child_span2 = %SpanRecord{
        span_id: "child2",
        parent_span_id: "root123",
        trace_id: "trace123",
        name: "child_span_2"
      }

      SpanStorage.store_span(root_span)
      SpanStorage.store_span(child_span1)
      SpanStorage.store_span(child_span2)

      assert root_span == SpanStorage.get_root_span("root123")
      assert length(SpanStorage.get_child_spans("root123")) == 2

      SpanStorage.remove_span("root123")

      assert nil == SpanStorage.get_root_span("root123")
      assert [] == SpanStorage.get_child_spans("root123")
    end
  end

  describe "child spans" do
    test "stores and retrieves child spans" do
      child_span1 = %SpanRecord{
        span_id: "child1",
        parent_span_id: "parent123",
        trace_id: "trace123",
        name: "child_span_1"
      }

      child_span2 = %SpanRecord{
        span_id: "child2",
        parent_span_id: "parent123",
        trace_id: "trace123",
        name: "child_span_2"
      }

      SpanStorage.store_span(child_span1)
      SpanStorage.store_span(child_span2)

      children = SpanStorage.get_child_spans("parent123")
      assert length(children) == 2
      assert child_span1 in children
      assert child_span2 in children
    end

    test "updates an existing child span" do
      child_span = %SpanRecord{
        span_id: "child1",
        parent_span_id: "parent123",
        trace_id: "trace123",
        name: "child_span"
      }

      updated_child_span = %SpanRecord{
        span_id: "child1",
        parent_span_id: "parent123",
        trace_id: "trace123",
        name: "updated_child_span"
      }

      SpanStorage.store_span(child_span)
      SpanStorage.update_span(updated_child_span)

      children = SpanStorage.get_child_spans("parent123")
      assert [^updated_child_span] = children
    end

    test "removes child spans" do
      child_span1 = %SpanRecord{
        span_id: "child1",
        parent_span_id: "parent123",
        trace_id: "trace123",
        name: "child_span_1"
      }

      child_span2 = %SpanRecord{
        span_id: "child2",
        parent_span_id: "parent123",
        trace_id: "trace123",
        name: "child_span_2"
      }

      SpanStorage.store_span(child_span1)
      SpanStorage.store_span(child_span2)
      assert length(SpanStorage.get_child_spans("parent123")) == 2

      SpanStorage.remove_child_spans("parent123")
      assert [] == SpanStorage.get_child_spans("parent123")
    end
  end

  test "handles complete span hierarchy" do
    root_span = %SpanRecord{
      span_id: "root123",
      parent_span_id: nil,
      trace_id: "trace123",
      name: "root_span"
    }

    child_span1 = %SpanRecord{
      span_id: "child1",
      parent_span_id: "root123",
      trace_id: "trace123",
      name: "child_span_1"
    }

    child_span2 = %SpanRecord{
      span_id: "child2",
      parent_span_id: "root123",
      trace_id: "trace123",
      name: "child_span_2"
    }

    SpanStorage.store_span(root_span)
    SpanStorage.store_span(child_span1)
    SpanStorage.store_span(child_span2)

    assert ^root_span = SpanStorage.get_root_span("root123")

    children = SpanStorage.get_child_spans("root123")
    assert length(children) == 2
    assert child_span1 in children
    assert child_span2 in children

    SpanStorage.remove_span("root123")
    SpanStorage.remove_child_spans("root123")

    assert nil == SpanStorage.get_root_span("root123")
    assert [] == SpanStorage.get_child_spans("root123")
  end

  describe "stale span cleanup" do
    test "cleans up stale spans" do
      start_supervised!({SpanStorage, cleanup_interval: 100, name: :cleanup_test})

      root_span = %SpanRecord{
        span_id: "stale_root",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "stale_root_span"
      }

      child_span = %SpanRecord{
        span_id: "stale_child",
        parent_span_id: "stale_root",
        trace_id: "trace123",
        name: "stale_child_span"
      }

      old_time = System.system_time(:second) - :timer.minutes(31)
      :ets.insert(:span_storage, {{:root_span, "stale_root"}, {root_span, old_time}})
      :ets.insert(:span_storage, {"stale_root", {child_span, old_time}})

      fresh_root_span = %SpanRecord{
        span_id: "fresh_root",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "fresh_root_span"
      }

      SpanStorage.store_span(fresh_root_span)

      Process.sleep(200)

      assert nil == SpanStorage.get_root_span("stale_root")
      assert [] == SpanStorage.get_child_spans("stale_root")

      assert SpanStorage.get_root_span("fresh_root")
    end

    test "cleans up orphaned child spans" do
      start_supervised!({SpanStorage, cleanup_interval: 100, name: :cleanup_test})

      child_span = %SpanRecord{
        span_id: "stale_child",
        parent_span_id: "non_existent_parent",
        trace_id: "trace123",
        name: "stale_child_span"
      }

      old_time = System.system_time(:second) - :timer.minutes(31)
      :ets.insert(:span_storage, {"non_existent_parent", {child_span, old_time}})

      Process.sleep(200)

      assert [] == SpanStorage.get_child_spans("non_existent_parent")
    end

    test "cleans up expired root spans with all their children regardless of child timestamps" do
      start_supervised!({SpanStorage, cleanup_interval: 100, name: :cleanup_test})

      root_span = %SpanRecord{
        span_id: "root123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span"
      }

      old_child = %SpanRecord{
        span_id: "old_child",
        parent_span_id: "root123",
        trace_id: "trace123",
        name: "old_child_span"
      }

      fresh_child = %SpanRecord{
        span_id: "fresh_child",
        parent_span_id: "root123",
        trace_id: "trace123",
        name: "fresh_child_span"
      }

      old_time = System.system_time(:second) - :timer.minutes(31)
      :ets.insert(:span_storage, {{:root_span, "root123"}, {root_span, old_time}})

      :ets.insert(:span_storage, {"root123", {old_child, old_time}})
      SpanStorage.store_span(fresh_child)

      Process.sleep(200)

      assert nil == SpanStorage.get_root_span("root123")
      assert [] == SpanStorage.get_child_spans("root123")
    end

    test "handles mixed expiration times in child spans" do
      start_supervised!({SpanStorage, cleanup_interval: 100, name: :cleanup_test})

      root_span = %SpanRecord{
        span_id: "root123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span"
      }

      old_child1 = %SpanRecord{
        span_id: "old_child1",
        parent_span_id: "root123",
        trace_id: "trace123",
        name: "old_child_span_1"
      }

      old_child2 = %SpanRecord{
        span_id: "old_child2",
        parent_span_id: "root123",
        trace_id: "trace123",
        name: "old_child_span_2"
      }

      fresh_child = %SpanRecord{
        span_id: "fresh_child",
        parent_span_id: "root123",
        trace_id: "trace123",
        name: "fresh_child_span"
      }

      SpanStorage.store_span(root_span)

      old_time = System.system_time(:second) - :timer.minutes(31)
      :ets.insert(:span_storage, {"root123", {old_child1, old_time}})
      :ets.insert(:span_storage, {"root123", {old_child2, old_time}})

      SpanStorage.store_span(fresh_child)

      Process.sleep(200)

      assert root_span == SpanStorage.get_root_span("root123")
      children = SpanStorage.get_child_spans("root123")
      assert length(children) == 1
      assert fresh_child in children
      refute old_child1 in children
      refute old_child2 in children
    end
  end
end
