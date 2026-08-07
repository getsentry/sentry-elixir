defmodule Sentry.Opentelemetry.AsyncTracesTest do
  # Asserts only on reported envelopes, never on span-processing internals,
  # so this coverage holds across changes to how spans are processed.

  use Sentry.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer

  import Sentry.Test.Assertions
  import Sentry.TestHelpers

  setup do
    setup_bypass()
  end

  describe "spans that start after their trace's root span has ended" do
    test "are reported as a follow-up transaction in the same trace", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass)

      parent_ctx =
        Tracer.with_span "sync_root" do
          :otel_ctx.get_current()
        end

      Task.async(fn ->
        Process.sleep(25)

        token = :otel_ctx.attach(parent_ctx)

        try do
          Tracer.with_span "async_parent" do
            Tracer.with_span "async_child" do
              Process.sleep(1)
            end
          end
        after
          :otel_ctx.detach(token)
        end
      end)
      |> Task.await()

      transactions = collect_sentry_transactions(ref, 2, timeout: 1000)

      root_tx = find_sentry_report!(transactions, transaction: "sync_root")
      async_tx = find_sentry_report!(transactions, transaction: "async_parent")

      root_trace = root_tx["contexts"]["trace"]
      async_trace = async_tx["contexts"]["trace"]

      assert async_trace["trace_id"] == root_trace["trace_id"]
      assert async_trace["parent_span_id"] == root_trace["span_id"]
      assert async_trace["data"]["sentry.parent_span_already_sent"] == true

      assert [child_span] = async_tx["spans"]
      assert child_span["op"] == "async_child"
      assert child_span["parent_span_id"] == async_trace["span_id"]
      assert child_span["trace_id"] == root_trace["trace_id"]
    end
  end

  describe "a child span that is still running when the transaction root ends" do
    test "is not reported without an end timestamp", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass)

      test_pid = self()

      task =
        Tracer.with_span "sync_root" do
          ctx = :otel_ctx.get_current()

          task =
            Task.async(fn ->
              token = :otel_ctx.attach(ctx)

              try do
                Tracer.with_span "in_flight_child" do
                  send(test_pid, :child_started)

                  receive do
                    :finish_child -> :ok
                  end
                end
              after
                :otel_ctx.detach(token)
              end
            end)

          assert_receive :child_started, 1000
          task
        end

      [root_tx] = collect_sentry_transactions(ref, 1)
      assert root_tx["transaction"] == "sync_root"

      assert Enum.all?(root_tx["spans"], & &1["timestamp"]),
             "transaction contains spans without an end timestamp: " <>
               inspect(root_tx["spans"])

      send(task.pid, :finish_child)
      Task.await(task)
    end

    test "is reported as a follow-up transaction once it finishes", %{bypass: bypass} do
      put_test_config(environment_name: "test", traces_sample_rate: 1.0)
      ref = setup_bypass_envelope_collector(bypass)

      test_pid = self()

      task =
        Tracer.with_span "sync_root" do
          ctx = :otel_ctx.get_current()

          task =
            Task.async(fn ->
              token = :otel_ctx.attach(ctx)

              try do
                Tracer.with_span "in_flight_child" do
                  send(test_pid, :child_started)

                  receive do
                    :finish_child -> :ok
                  end
                end
              after
                :otel_ctx.detach(token)
              end
            end)

          assert_receive :child_started, 1000
          task
        end

      [root_tx] = collect_sentry_transactions(ref, 1)
      assert root_tx["transaction"] == "sync_root"

      send(task.pid, :finish_child)
      Task.await(task)

      assert [child_tx] = collect_sentry_transactions(ref, 1),
             "no follow-up transaction was reported for the late-finishing child"

      assert child_tx["transaction"] == "in_flight_child"

      root_trace = root_tx["contexts"]["trace"]
      child_trace = child_tx["contexts"]["trace"]

      assert child_trace["trace_id"] == root_trace["trace_id"]
      assert child_trace["parent_span_id"] == root_trace["span_id"]
    end
  end
end
