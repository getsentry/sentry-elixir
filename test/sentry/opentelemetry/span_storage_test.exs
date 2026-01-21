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

  describe "span_exists?" do
    @tag span_storage: true
    test "returns true for existing root span", %{table_name: table_name} do
      root_span = %SpanRecord{
        span_id: "root123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span"
      }

      SpanStorage.store_span(root_span, table_name: table_name)

      assert SpanStorage.span_exists?("root123", table_name: table_name) == true
    end

    @tag span_storage: true
    test "returns true for existing child span", %{table_name: table_name} do
      child_span = %SpanRecord{
        span_id: "child123",
        parent_span_id: "parent123",
        trace_id: "trace123",
        name: "child_span"
      }

      SpanStorage.store_span(child_span, table_name: table_name)

      assert SpanStorage.span_exists?("child123", table_name: table_name) == true
    end

    @tag span_storage: true
    test "returns false for non-existent span", %{table_name: table_name} do
      assert SpanStorage.span_exists?("nonexistent", table_name: table_name) == false
    end

    @tag span_storage: true
    test "returns true for HTTP server span with remote parent (distributed tracing)", %{
      table_name: table_name
    } do
      # HTTP server span with a remote parent (from distributed tracing)
      # is stored as a child span, not a root span
      http_server_span = %SpanRecord{
        span_id: "http_span_123",
        parent_span_id: "remote_parent_456",
        trace_id: "trace123",
        name: "GET /users"
      }

      SpanStorage.store_span(http_server_span, table_name: table_name)

      assert SpanStorage.span_exists?("http_span_123", table_name: table_name) == true
      assert SpanStorage.span_exists?("remote_parent_456", table_name: table_name) == false
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

      old_time = DateTime.utc_now() |> DateTime.add(-1860, :second) |> DateTime.to_unix()

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

      # 31 minutes = 1860 seconds
      old_time = DateTime.utc_now() |> DateTime.add(-1860, :second) |> DateTime.to_unix()
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

      old_time = DateTime.utc_now() |> DateTime.add(-1860, :second) |> DateTime.to_unix()
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

      old_time = DateTime.utc_now() |> DateTime.add(-1860, :second) |> DateTime.to_unix()
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

  describe "nested span hierarchies" do
    @tag span_storage: true
    test "retrieves grand-children spans correctly", %{table_name: table_name} do
      root_span = %SpanRecord{
        span_id: "root123",
        parent_span_id: nil,
        trace_id: "trace123",
        name: "root_span",
        start_time: 1000,
        end_time: 2000
      }

      child1_span = %SpanRecord{
        span_id: "child1",
        parent_span_id: "root123",
        trace_id: "trace123",
        name: "child_span_1",
        start_time: 1100,
        end_time: 1900
      }

      child2_span = %SpanRecord{
        span_id: "child2",
        parent_span_id: "root123",
        trace_id: "trace123",
        name: "child_span_2",
        start_time: 1200,
        end_time: 1800
      }

      grandchild1_span = %SpanRecord{
        span_id: "grandchild1",
        parent_span_id: "child1",
        trace_id: "trace123",
        name: "grandchild_span_1",
        start_time: 1150,
        end_time: 1250
      }

      grandchild2_span = %SpanRecord{
        span_id: "grandchild2",
        parent_span_id: "child1",
        trace_id: "trace123",
        name: "grandchild_span_2",
        start_time: 1300,
        end_time: 1400
      }

      grandchild3_span = %SpanRecord{
        span_id: "grandchild3",
        parent_span_id: "child2",
        trace_id: "trace123",
        name: "grandchild_span_3",
        start_time: 1250,
        end_time: 1350
      }

      SpanStorage.store_span(root_span, table_name: table_name)
      SpanStorage.store_span(child1_span, table_name: table_name)
      SpanStorage.store_span(child2_span, table_name: table_name)
      SpanStorage.store_span(grandchild1_span, table_name: table_name)
      SpanStorage.store_span(grandchild2_span, table_name: table_name)
      SpanStorage.store_span(grandchild3_span, table_name: table_name)

      all_descendants = SpanStorage.get_child_spans("root123", table_name: table_name)

      assert length(all_descendants) == 5

      span_ids = Enum.map(all_descendants, & &1.span_id)
      assert "child1" in span_ids
      assert "child2" in span_ids
      assert "grandchild1" in span_ids
      assert "grandchild2" in span_ids
      assert "grandchild3" in span_ids

      start_times = Enum.map(all_descendants, & &1.start_time)
      assert start_times == Enum.sort(start_times)
    end

    @tag span_storage: true
    test "retrieves deep nested hierarchies correctly", %{table_name: table_name} do
      spans = [
        %SpanRecord{
          span_id: "root",
          parent_span_id: nil,
          trace_id: "trace123",
          name: "root_span",
          start_time: 1000,
          end_time: 2000
        },
        %SpanRecord{
          span_id: "child",
          parent_span_id: "root",
          trace_id: "trace123",
          name: "child_span",
          start_time: 1100,
          end_time: 1900
        },
        %SpanRecord{
          span_id: "grandchild",
          parent_span_id: "child",
          trace_id: "trace123",
          name: "grandchild_span",
          start_time: 1200,
          end_time: 1800
        },
        %SpanRecord{
          span_id: "great_grandchild",
          parent_span_id: "grandchild",
          trace_id: "trace123",
          name: "great_grandchild_span",
          start_time: 1300,
          end_time: 1700
        }
      ]

      Enum.each(spans, &SpanStorage.store_span(&1, table_name: table_name))

      all_descendants = SpanStorage.get_child_spans("root", table_name: table_name)
      assert length(all_descendants) == 3

      span_ids = Enum.map(all_descendants, & &1.span_id)
      assert "child" in span_ids
      assert "grandchild" in span_ids
      assert "great_grandchild" in span_ids

      child_descendants = SpanStorage.get_child_spans("child", table_name: table_name)
      assert length(child_descendants) == 2

      child_span_ids = Enum.map(child_descendants, & &1.span_id)
      assert "grandchild" in child_span_ids
      assert "great_grandchild" in child_span_ids

      grandchild_descendants = SpanStorage.get_child_spans("grandchild", table_name: table_name)
      assert length(grandchild_descendants) == 1
      assert hd(grandchild_descendants).span_id == "great_grandchild"
    end

    @tag span_storage: true
    test "handles multiple disconnected subtrees correctly", %{table_name: table_name} do
      spans = [
        %SpanRecord{
          span_id: "branch1",
          parent_span_id: "root",
          trace_id: "trace123",
          name: "branch1_span",
          start_time: 1100,
          end_time: 1500
        },
        %SpanRecord{
          span_id: "leaf1",
          parent_span_id: "branch1",
          trace_id: "trace123",
          name: "leaf1_span",
          start_time: 1150,
          end_time: 1250
        },
        %SpanRecord{
          span_id: "leaf2",
          parent_span_id: "branch1",
          trace_id: "trace123",
          name: "leaf2_span",
          start_time: 1300,
          end_time: 1400
        },
        %SpanRecord{
          span_id: "branch2",
          parent_span_id: "root",
          trace_id: "trace123",
          name: "branch2_span",
          start_time: 1600,
          end_time: 1900
        },
        %SpanRecord{
          span_id: "leaf3",
          parent_span_id: "branch2",
          trace_id: "trace123",
          name: "leaf3_span",
          start_time: 1650,
          end_time: 1750
        }
      ]

      Enum.each(spans, &SpanStorage.store_span(&1, table_name: table_name))

      all_descendants = SpanStorage.get_child_spans("root", table_name: table_name)
      assert length(all_descendants) == 5

      span_ids = Enum.map(all_descendants, & &1.span_id)
      assert "branch1" in span_ids
      assert "branch2" in span_ids
      assert "leaf1" in span_ids
      assert "leaf2" in span_ids
      assert "leaf3" in span_ids

      start_times = Enum.map(all_descendants, & &1.start_time)
      assert start_times == [1100, 1150, 1300, 1600, 1650]
    end
  end

  describe "cleanup" do
    @tag span_storage: [cleanup_interval: 100]
    test "cleanup respects span TTL precisely", %{table_name: table_name} do
      now = System.system_time(:second)
      ttl = 1800

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
