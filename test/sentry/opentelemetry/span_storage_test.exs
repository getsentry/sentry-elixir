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
      assert SpanStorage.get_root_span("abc123", table_name: table_name) == nil
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

      assert SpanStorage.get_root_span("root123", table_name: table_name) == nil
      assert SpanStorage.get_child_spans("root123", table_name: table_name) == []
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

    assert SpanStorage.get_root_span("root123", table_name: table_name) == nil
    assert SpanStorage.get_child_spans("root123", table_name: table_name) == []
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
      :ets.insert(table_name, {{:child_span, "stale_root", "stale_child"}, child_span, old_time})

      fresh_root_span = %SpanRecord{
        span_id: "fresh_root",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "fresh_root_span"
      }

      SpanStorage.store_span(fresh_root_span, table_name: table_name)

      Process.sleep(200)

      assert SpanStorage.get_root_span("stale_root", table_name: table_name) == nil
      assert SpanStorage.get_child_spans("stale_root", table_name: table_name) == []

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

      assert SpanStorage.get_root_span("root123", table_name: table_name) == nil
      assert SpanStorage.get_child_spans("root123", table_name: table_name) == []
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

  describe "concurrent operations" do
    @tag span_storage: true
    test "handles concurrent span updates safely", %{table_name: table_name} do
      root_span = %SpanRecord{
        span_id: "root123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span"
      }

      SpanStorage.store_span(root_span, table_name: table_name)

      tasks =
        for i <- 1..10000 do
          Task.async(fn ->
            updated_span = %{root_span | name: "updated_name_#{i}"}
            SpanStorage.update_span(updated_span, table_name: table_name)
          end)
        end

      Task.await_many(tasks)

      result = SpanStorage.get_root_span("root123", table_name: table_name)
      assert result.span_id == "root123"
      assert result.name =~ ~r/^updated_name_\d+$/
    end

    @tag span_storage: true
    test "handles concurrent child span operations", %{table_name: table_name} do
      parent_id = "parent123"

      tasks =
        for i <- 1..10000 do
          Task.async(fn ->
            child_span = %SpanRecord{
              span_id: "child_#{i}",
              parent_span_id: parent_id,
              trace_id: "trace123",
              name: "child_span_#{i}"
            }

            SpanStorage.store_span(child_span, table_name: table_name)
          end)
        end

      Task.await_many(tasks)

      children = SpanStorage.get_child_spans(parent_id, table_name: table_name)
      assert length(children) == 10000
      assert Enum.all?(children, &(&1.parent_span_id == parent_id))
    end
  end

  describe "span timestamps" do
    @tag span_storage: true
    test "maintains correct timestamp ordering", %{table_name: table_name} do
      now = System.system_time(:second)

      spans =
        for i <- 1..5 do
          %SpanRecord{
            span_id: "span_#{i}",
            parent_span_id: "parent123",
            trace_id: "trace123",
            name: "span_#{i}",
            start_time: now + i,
            end_time: now + i + 10
          }
        end

      Enum.reverse(spans)
      |> Enum.each(&SpanStorage.store_span(&1, table_name: table_name))

      retrieved_spans = SpanStorage.get_child_spans("parent123", table_name: table_name)
      assert length(retrieved_spans) == 5

      assert retrieved_spans
             |> Enum.map(& &1.start_time)
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> a <= b end)
    end
  end

  describe "cleanup" do
    @tag span_storage: [cleanup_interval: 100]
    test "cleanup respects span TTL precisely", %{table_name: table_name} do
      now = System.system_time(:second)
      ttl = :timer.minutes(30)

      spans = [
        {now - ttl - 1, "too_old"},
        {now - ttl + 1, "just_fresh"},
        {now - div(ttl, 2), "middle_aged"},
        {now, "fresh"}
      ]

      Enum.each(spans, fn {timestamp, name} ->
        span = %SpanRecord{
          span_id: name,
          parent_span_id: nil,
          trace_id: "trace123",
          name: name
        }

        :ets.insert(table_name, {{:root_span, name}, span, timestamp})
      end)

      Process.sleep(200)

      assert SpanStorage.get_root_span("too_old", table_name: table_name) == nil
      assert not is_nil(SpanStorage.get_root_span("just_fresh", table_name: table_name))
      assert not is_nil(SpanStorage.get_root_span("middle_aged", table_name: table_name))
      assert not is_nil(SpanStorage.get_root_span("fresh", table_name: table_name))
    end

    @tag span_storage: [cleanup_interval: 100]
    test "cleanup handles large number of expired spans efficiently", %{table_name: table_name} do
      old_time = System.system_time(:second) - :timer.minutes(31)

      for i <- 1..10000 do
        root_span = %SpanRecord{
          span_id: "span_#{i}",
          parent_span_id: nil,
          trace_id: "trace123",
          name: "span_#{i}"
        }

        :ets.insert(table_name, {{:root_span, "span_#{i}"}, root_span, old_time})
      end

      Process.sleep(200)

      assert :ets.info(table_name, :size) == 0
    end
  end
end
