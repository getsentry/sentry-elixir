defmodule Sentry.OpenTelemetry.SpanStorageTest do
  use Sentry.Case, async: true

  alias Sentry.OpenTelemetry.{SpanStorage, SpanRecord}

  describe "root spans" do
    @tag span_storage: true
    test "stores and retrieves a root span", %{table_name: table_name} do
      root_span = %SpanRecord{
        span_id: "abc123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span"
      }

      SpanStorage.store_span(root_span, table_name: table_name)

      assert ^root_span = SpanStorage.get_root_span("abc123", table_name: table_name)
    end

    @tag span_storage: true
    test "updates an existing root span", %{table_name: table_name} do
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

      SpanStorage.store_span(root_span, table_name: table_name)
      SpanStorage.update_span(updated_root_span, table_name: table_name)

      assert ^updated_root_span = SpanStorage.get_root_span("abc123", table_name: table_name)
    end

    @tag span_storage: true
    test "removes a root span", %{table_name: table_name} do
      root_span = %SpanRecord{
        span_id: "abc123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span"
      }

      SpanStorage.store_span(root_span, table_name: table_name)
      assert root_span == SpanStorage.get_root_span("abc123", table_name: table_name)

      SpanStorage.remove_root_span("abc123", table_name: table_name)
      assert nil == SpanStorage.get_root_span("abc123", table_name: table_name)
    end

    @tag span_storage: true
    test "removes root span and all its children", %{table_name: table_name} do
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

      SpanStorage.store_span(root_span, table_name: table_name)
      SpanStorage.store_span(child_span1, table_name: table_name)
      SpanStorage.store_span(child_span2, table_name: table_name)

      assert root_span == SpanStorage.get_root_span("root123", table_name: table_name)
      assert length(SpanStorage.get_child_spans("root123", table_name: table_name)) == 2

      SpanStorage.remove_root_span("root123", table_name: table_name)

      assert nil == SpanStorage.get_root_span("root123", table_name: table_name)
      assert [] == SpanStorage.get_child_spans("root123", table_name: table_name)
    end
  end

  describe "child spans" do
    @tag span_storage: true
    test "stores and retrieves child spans", %{table_name: table_name} do
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

      SpanStorage.store_span(child_span1, table_name: table_name)
      SpanStorage.store_span(child_span2, table_name: table_name)

      children = SpanStorage.get_child_spans("parent123", table_name: table_name)
      assert length(children) == 2
      assert child_span1 in children
      assert child_span2 in children
    end

    @tag span_storage: true
    test "updates an existing child span", %{table_name: table_name} do
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

      SpanStorage.store_span(child_span, table_name: table_name)
      SpanStorage.update_span(updated_child_span, table_name: table_name)

      children = SpanStorage.get_child_spans("parent123", table_name: table_name)
      assert [^updated_child_span] = children
    end

    @tag span_storage: true
    test "removes child spans", %{table_name: table_name} do
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

      SpanStorage.store_span(child_span1, table_name: table_name)
      SpanStorage.store_span(child_span2, table_name: table_name)
      assert length(SpanStorage.get_child_spans("parent123", table_name: table_name)) == 2

      SpanStorage.remove_child_spans("parent123", table_name: table_name)
      assert [] == SpanStorage.get_child_spans("parent123", table_name: table_name)
    end
  end

  @tag span_storage: true
  test "handles complete span hierarchy", %{table_name: table_name} do
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

    SpanStorage.store_span(root_span, table_name: table_name)
    SpanStorage.store_span(child_span1, table_name: table_name)
    SpanStorage.store_span(child_span2, table_name: table_name)

    assert ^root_span = SpanStorage.get_root_span("root123", table_name: table_name)

    children = SpanStorage.get_child_spans("root123", table_name: table_name)
    assert length(children) == 2
    assert child_span1 in children
    assert child_span2 in children

    SpanStorage.remove_root_span("root123", table_name: table_name)
    SpanStorage.remove_child_spans("root123", table_name: table_name)

    assert nil == SpanStorage.get_root_span("root123", table_name: table_name)
    assert [] == SpanStorage.get_child_spans("root123", table_name: table_name)
  end

  describe "stale span cleanup" do
    @tag span_storage: [cleanup_interval: 100]
    test "cleans up stale spans", %{table_name: table_name} do
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

      :ets.insert(table_name, {{:root_span, "stale_root"}, root_span, old_time})
      :ets.insert(table_name, {"stale_root", {child_span, old_time}})

      fresh_root_span = %SpanRecord{
        span_id: "fresh_root",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "fresh_root_span"
      }

      SpanStorage.store_span(fresh_root_span, table_name: table_name)

      Process.sleep(200)

      assert nil == SpanStorage.get_root_span("stale_root", table_name: table_name)
      assert [] == SpanStorage.get_child_spans("stale_root", table_name: table_name)

      assert SpanStorage.get_root_span("fresh_root", table_name: table_name)
    end

    @tag span_storage: [cleanup_interval: 100]
    test "cleans up orphaned child spans", %{table_name: table_name} do
      child_span = %SpanRecord{
        span_id: "stale_child",
        parent_span_id: "non_existent_parent",
        trace_id: "trace123",
        name: "stale_child_span"
      }

      old_time = System.system_time(:second) - :timer.minutes(31)
      :ets.insert(table_name, {"non_existent_parent", {child_span, old_time}})

      Process.sleep(200)

      assert [] == SpanStorage.get_child_spans("non_existent_parent", table_name: table_name)
    end

    @tag span_storage: [cleanup_interval: 100]
    test "cleans up expired root spans with all their children regardless of child timestamps", %{
      table_name: table_name
    } do
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
      :ets.insert(table_name, {{:root_span, "root123"}, root_span, old_time})

      :ets.insert(table_name, {"root123", {old_child, old_time}})
      SpanStorage.store_span(fresh_child, table_name: table_name)

      Process.sleep(200)

      assert nil == SpanStorage.get_root_span("root123", table_name: table_name)
      assert [] == SpanStorage.get_child_spans("root123", table_name: table_name)
    end

    @tag span_storage: [cleanup_interval: 100]
    test "handles mixed expiration times in child spans", %{table_name: table_name} do
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

      SpanStorage.store_span(root_span, table_name: table_name)

      old_time = System.system_time(:second) - :timer.minutes(31)
      :ets.insert(table_name, {"root123", {old_child1, old_time}})
      :ets.insert(table_name, {"root123", {old_child2, old_time}})

      SpanStorage.store_span(fresh_child, table_name: table_name)

      Process.sleep(200)

      assert root_span == SpanStorage.get_root_span("root123", table_name: table_name)
      children = SpanStorage.get_child_spans("root123", table_name: table_name)
      assert length(children) == 1
      assert fresh_child in children
      refute old_child1 in children
      refute old_child2 in children
    end
  end
end
