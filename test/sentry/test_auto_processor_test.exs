defmodule Sentry.TestAutoProcessorTest do
  # This module intentionally does NOT `use Sentry.Case` — it simulates a user of
  # the SDK who only has access to the public `Sentry.Test` helpers and verifies
  # that `setup_sentry/1` is sufficient to exercise the TelemetryProcessor
  # pipeline (logs, metrics, send_result: :none).
  use ExUnit.Case, async: false

  import Sentry.Test.Assertions

  alias Sentry.Test, as: SentryTest

  require Logger

  describe "setup_sentry/0 auto-starts a per-test TelemetryProcessor" do
    test "returns :telemetry_processor in the context map" do
      ctx = SentryTest.setup_sentry()

      assert is_map(ctx)
      assert Map.has_key?(ctx, :bypass)
      assert Map.has_key?(ctx, :telemetry_processor)

      processor_name = ctx.telemetry_processor
      assert is_atom(processor_name)
      assert Atom.to_string(processor_name) =~ ~r/^test_telemetry_processor_\d+$/
    end

    test "registers the processor in the process dictionary" do
      %{telemetry_processor: processor_name} = SentryTest.setup_sentry()

      assert Process.get(:sentry_telemetry_processor) == processor_name
    end

    test "the scheduler is allowed in this test's config scope" do
      %{telemetry_processor: processor_name} = SentryTest.setup_sentry()

      scheduler_pid = Sentry.TelemetryProcessor.get_scheduler(processor_name)
      assert is_pid(scheduler_pid)
      assert Process.alive?(scheduler_pid)
    end

    test "is idempotent — calling twice reuses the same processor" do
      %{telemetry_processor: first} = SentryTest.setup_sentry()
      second = SentryTest.setup_telemetry_processor()

      assert first == second
    end
  end

  describe "log events flow through the auto-started TelemetryProcessor" do
    @describetag :capture_log

    setup do
      ctx = SentryTest.setup_sentry(enable_logs: true, logs: [level: :info])

      handler_name = :"sentry_auto_processor_logs_#{System.unique_integer([:positive])}"

      handler_config = %{
        config: %{
          enable_logs: true
        }
      }

      :ok = :logger.add_handler(handler_name, Sentry.LoggerHandler, handler_config)

      on_exit(fn ->
        _ = :logger.remove_handler(handler_name)
      end)

      ctx
    end

    test "a log emitted via Logger is captured via the pipeline" do
      Logger.info("auto processor regression")

      assert_sentry_log(:info, "auto processor regression")
    end
  end
end
