defmodule Sentry.LoggerHandler.LogsTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers
  import Sentry.Test.Assertions

  alias Sentry.Test, as: SentryTest
  alias Sentry.TelemetryProcessor

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @moduletag :capture_log

  setup do
    SentryTest.setup_sentry(enable_logs: true, logs: [level: :info])
  end

  setup :add_logs_handler

  describe "adding handler" do
    test "accepts configuration", %{handler_name: handler_name} do
      assert {:ok, config} = :logger.get_handler_config(handler_name)
      assert is_struct(config.config, Sentry.LoggerHandler)
    end
  end

  describe "logging with handler" do
    test "creates log event and adds to buffer" do
      Logger.info("Test log message")

      log = assert_sentry_log(:info, "Test log message")
      assert is_number(log.timestamp)
    end

    test "filters logs below configured level" do
      put_test_config(logs: [level: :warning])

      initial_size = TelemetryProcessor.buffer_size(:log)

      Logger.info("Info message should be filtered")
      Logger.debug("Debug message should be filtered")

      wait_for_buffer_stable(nil, initial_size)

      assert TelemetryProcessor.buffer_size(:log) == initial_size
    end

    test "accepts logs at or above configured level" do
      Logger.info("Info message")
      Logger.warning("Warning message")
      Logger.error("Error message")

      assert_sentry_log(:info, "Info message")
      assert_sentry_log(:warn, "Warning message")
      assert_sentry_log(:error, "Error message")
    end

    test "filters excluded domains" do
      put_test_config(logs: [excluded_domains: [:cowboy]])

      initial_size = TelemetryProcessor.buffer_size(:log)

      Logger.info("Cowboy message", domain: [:cowboy])

      wait_for_buffer_stable(nil, initial_size)

      assert TelemetryProcessor.buffer_size(:log) == initial_size
    end

    test "includes logs from non-excluded domains" do
      put_test_config(logs: [excluded_domains: [:cowboy]])

      initial_size = TelemetryProcessor.buffer_size(:log)

      Logger.info("Regular message")
      Logger.info("Phoenix message", domain: [:phoenix])

      assert_buffer_size(nil, initial_size + 2)
    end

    test "includes metadata as attributes" do
      put_test_config(logs: [metadata: [:request_id, :user_id]])

      Logger.metadata(request_id: "abc123", user_id: 42, other_meta: "should not be included")
      Logger.info("Request processed")

      log =
        assert_sentry_log(:info, "Request processed",
          attributes: %{request_id: "abc123", user_id: 42}
        )

      refute Map.has_key?(log.attributes, :other_meta)
    end

    test "safely serializes struct metadata as string attributes" do
      put_test_config(logs: [metadata: [:my_uri]])

      uri = URI.parse("https://example.com/path")
      Logger.metadata(my_uri: uri)
      Logger.info("Request with struct metadata")

      # Structs are stringified via inspect/1 when the envelope is built; the
      # collected LogEvent still holds the original struct.
      log = assert_sentry_log(:info, "Request with struct metadata")
      assert log.attributes[:my_uri] == uri
    end

    test "includes all metadata when configured with :all" do
      put_test_config(logs: [metadata: :all])

      Logger.metadata(request_id: "abc123", user_id: 42, custom_field: "value")
      Logger.info("Request with metadata")

      assert_sentry_log(:info, "Request with metadata",
        attributes: %{request_id: "abc123", user_id: 42, custom_field: "value"}
      )
    end

    test "does not send logs when enable_logs is false at handler setup time", %{
      handler_name: handler_name
    } do
      # Remove the main handler first so we can test with enable_logs: false
      :ok = :logger.remove_handler(handler_name)

      disabled_handler_name =
        :"sentry_logs_handler_disabled_#{System.unique_integer([:positive])}"

      # Set enable_logs to false BEFORE adding a new handler
      put_test_config(enable_logs: false)

      handler_config = %{config: %{}}

      # Add handler with enable_logs: false - LogsBackend should NOT be included
      assert :ok =
               :logger.add_handler(disabled_handler_name, Sentry.LoggerHandler, handler_config)

      on_exit(fn ->
        _ = :logger.remove_handler(disabled_handler_name)
      end)

      initial_size = TelemetryProcessor.buffer_size(:log)

      Logger.info("Test message")

      # Give some time for the log to be processed
      Process.sleep(100)

      # Buffer should still be at initial size because LogsBackend was not enabled
      assert TelemetryProcessor.buffer_size(:log) == initial_size
    end

    test "handler-level enable_logs: false overrides global enable_logs: true", %{
      handler_name: handler_name
    } do
      :ok = :logger.remove_handler(handler_name)

      override_handler_name =
        :"sentry_logs_handler_override_#{System.unique_integer([:positive])}"

      # Global config says logs are on; handler-level override forces them off.
      put_test_config(enable_logs: true)

      assert :ok =
               :logger.add_handler(override_handler_name, Sentry.LoggerHandler, %{
                 config: %{enable_logs: false}
               })

      on_exit(fn -> _ = :logger.remove_handler(override_handler_name) end)

      initial_size = TelemetryProcessor.buffer_size(:log)

      Logger.info("Test message — should be ignored by overridden handler")

      Process.sleep(100)

      assert TelemetryProcessor.buffer_size(:log) == initial_size
    end

    test "rejects non-boolean :enable_logs in handler config", %{handler_name: handler_name} do
      :ok = :logger.remove_handler(handler_name)

      invalid_handler_name =
        :"sentry_logs_handler_invalid_#{System.unique_integer([:positive])}"

      assert {:error, {:handler_not_added, {:callback_crashed, {:error, error, _stack}}}} =
               :logger.add_handler(invalid_handler_name, Sentry.LoggerHandler, %{
                 config: %{enable_logs: "true"}
               })

      assert %NimbleOptions.ValidationError{key: :enable_logs} = error
    end

    test "generates trace_id when no trace context is available" do
      Logger.info("Log without trace")

      log = assert_sentry_log(:info, "Log without trace")
      assert is_binary(log.trace_id)
      assert log.trace_id =~ ~r/^[0-9a-f]{32}$/
    end

    test "captures message template with %s parameters via Logger metadata" do
      Logger.info("User %s logged in from %s", parameters: ["jane_doe", "192.168.1.1"])

      log = assert_sentry_log(:info, "User jane_doe logged in from 192.168.1.1")
      assert log.template == "User %s logged in from %s"
      assert log.parameters == ["jane_doe", "192.168.1.1"]
    end

    test "captures message template with %{key} named parameters" do
      Logger.info("Hello %{name} from %{city}", parameters: %{name: "Jane", city: "NYC"})

      log = assert_sentry_log(:info, "Hello Jane from NYC")
      assert log.template == "Hello %{name} from %{city}"
      assert log.parameters == ["Jane", "NYC"]
    end

    test "does not include template attributes for plain string messages" do
      Logger.info("Simple log message")

      log = assert_sentry_log(:info, "Simple log message")
      assert is_nil(log.template)
      assert is_nil(log.parameters)
    end
  end

  describe "OpenTelemetry integration with opentelemetry_logger_metadata" do
    setup do
      :ok = OpentelemetryLoggerMetadata.setup()

      on_exit(fn ->
        _ = :logger.remove_primary_filter(:opentelemetry_logger_metadata)
      end)

      :ok
    end

    test "automatically includes trace context from OpenTelemetry spans" do
      Tracer.with_span "test_span" do
        Logger.info("Log inside OTel span")
      end

      log = assert_sentry_log(:info, "Log inside OTel span")
      assert log.trace_id =~ ~r/^[0-9a-f]{32}$/
      assert log.span_id =~ ~r/^[0-9a-f]{16}$/
    end

    test "includes trace context from nested OpenTelemetry spans" do
      Tracer.with_span "parent_span" do
        Logger.info("Log in parent span")

        Tracer.with_span "child_span" do
          Logger.info("Log in child span")
        end
      end

      parent_log = assert_sentry_log(:info, "Log in parent span")
      child_log = assert_sentry_log(:info, "Log in child span")

      assert parent_log.trace_id == child_log.trace_id
      assert parent_log.span_id != child_log.span_id
    end

    test "works out-of-the-box when handler is configured" do
      Tracer.with_span "api_call" do
        Logger.info("Processing API request")
      end

      log = assert_sentry_log(:info, "Processing API request")
      assert log.trace_id =~ ~r/^[0-9a-f]{32}$/
      assert is_binary(log.span_id)
    end
  end

  describe "before_send_log callback" do
    # `put_test_config(before_send_log: ...)` replaces the collector wrapper
    # installed by setup_sentry/1, so we install our own wrapper that applies
    # the user's logic and writes the (possibly modified) log event directly
    # into the test's ETS collector.
    defp install_before_send_log(user_fn) do
      collector_table = Process.get(:sentry_test_collector)

      apply_fn = fn event ->
        case user_fn do
          {mod, fun} -> apply(mod, fun, [event])
          fun when is_function(fun, 1) -> fun.(event)
        end
      end

      put_test_config(
        before_send_log: fn log_event ->
          case apply_fn.(log_event) do
            nil ->
              nil

            false ->
              false

            modified ->
              :ets.insert(
                collector_table,
                {System.unique_integer([:monotonic]), modified}
              )

              modified
          end
        end
      )
    end

    test "allows modifying log events before sending" do
      install_before_send_log(fn log_event ->
        %{log_event | attributes: Map.put(log_event.attributes, "custom_attr", "injected")}
      end)

      Logger.info("Test message")

      log = assert_sentry_log(:info, "Test message")
      assert log.attributes["custom_attr"] == "injected"
    end

    test "filters out log events when callback returns nil" do
      install_before_send_log(fn log_event ->
        if String.contains?(log_event.body, "should_be_filtered"), do: nil, else: log_event
      end)

      Logger.info("This message should_be_filtered")
      Logger.info("This message should pass")

      assert_sentry_log(:info, "This message should pass")
      assert SentryTest.pop_sentry_logs() == []
    end

    test "filters out log events when callback returns false" do
      install_before_send_log(fn log_event ->
        if String.contains?(log_event.body, "drop_me"), do: false, else: log_event
      end)

      Logger.info("drop_me please")
      Logger.info("Keep this message")

      assert_sentry_log(:info, "Keep this message")
      assert SentryTest.pop_sentry_logs() == []
    end

    test "supports MFA tuple callback format" do
      install_before_send_log({__MODULE__, :before_send_log_callback})

      Logger.info("Test MFA callback")

      log = assert_sentry_log(:info, "Test MFA callback")
      assert log.attributes["mfa_added"] == "true"
    end

    test "does not send any logs when all are filtered" do
      install_before_send_log(fn _log_event -> nil end)

      Logger.info("All messages filtered 1")
      Logger.info("All messages filtered 2")

      TelemetryProcessor.flush()
      assert SentryTest.pop_sentry_logs() == []
    end
  end

  def before_send_log_callback(log_event) do
    %{log_event | attributes: Map.put(log_event.attributes, "mfa_added", "true")}
  end

  defp add_logs_handler(%{telemetry_processor: telemetry_processor}) do
    handler_name = :"sentry_logs_handler_#{System.unique_integer([:positive])}"

    handler_config = %{
      config: %{
        telemetry_processor: telemetry_processor
      }
    }

    assert :ok = :logger.add_handler(handler_name, Sentry.LoggerHandler, handler_config)

    on_exit(fn ->
      _ = :logger.remove_handler(handler_name)
    end)

    %{handler_name: handler_name}
  end

  defp assert_buffer_size(_buffer, expected_size, timeout \\ 1000) do
    wait_until(fn -> TelemetryProcessor.buffer_size(:log) == expected_size end, timeout)
    assert TelemetryProcessor.buffer_size(:log) == expected_size
  end

  defp wait_for_buffer_stable(_buffer, expected_size, timeout \\ 1000) do
    wait_until(fn -> TelemetryProcessor.buffer_size(:log) == expected_size end, timeout)
  end

  defp wait_until(condition_fn, timeout) do
    end_time = System.monotonic_time(:millisecond) + timeout
    wait_until_loop(condition_fn, end_time, 1)
  end

  defp wait_until_loop(condition_fn, end_time, sleep_time) do
    cond do
      condition_fn.() ->
        :ok

      System.monotonic_time(:millisecond) >= end_time ->
        :timeout

      true ->
        Process.sleep(sleep_time)
        next_sleep = min(sleep_time * 2, 50)
        wait_until_loop(condition_fn, end_time, next_sleep)
    end
  end
end
