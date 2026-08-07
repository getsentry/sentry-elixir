defmodule Sentry.Opentelemetry.AsyncTracesTest do
  # Asserts only on reported envelopes, never on span-processing internals,
  # so this coverage holds across changes to how spans are processed.

  use Sentry.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer

  import Sentry.TestHelpers

  setup do
    setup_bypass()
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
  end
end
