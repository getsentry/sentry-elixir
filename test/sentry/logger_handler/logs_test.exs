defmodule Sentry.LoggerHandler.LogsTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.TelemetryProcessor

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @moduletag :capture_log

  setup do
    bypass = Bypass.open()

    put_test_config(
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      enable_logs: true,
      logs: [level: :info]
    )

    # TelemetryProcessor is already started by Sentry.Case
    %{bypass: bypass}
  end

  setup :add_logs_handler

  describe "adding handler" do
    test "accepts configuration", %{handler_name: handler_name} do
      assert {:ok, config} = :logger.get_handler_config(handler_name)
      assert is_struct(config.config, Sentry.LoggerHandler)
    end
  end

  describe "logging with handler" do
    test "creates log event and adds to buffer", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, item_header, item_body, _] = String.split(body, "\n")

        item_header_map = decode!(item_header)
        assert item_header_map["type"] == "log"
        assert item_header_map["item_count"] == 1
        assert item_header_map["content_type"] == "application/vnd.sentry.items.log+json"

        item_body_map = decode!(item_body)
        assert %{"items" => [log_event]} = item_body_map
        assert log_event["body"] == "Test log message"
        assert log_event["level"] == "info"
        assert is_number(log_event["timestamp"])

        send(test_pid, :envelope_sent)

        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      initial_size = TelemetryProcessor.buffer_size(:log)

      Logger.info("Test log message")

      assert_buffer_size(nil, initial_size + 1)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "filters logs below configured level" do
      put_test_config(logs: [level: :warning])

      initial_size = TelemetryProcessor.buffer_size(:log)

      Logger.info("Info message should be filtered")
      Logger.debug("Debug message should be filtered")

      wait_for_buffer_stable(nil, initial_size)

      assert TelemetryProcessor.buffer_size(:log) == initial_size
    end

    test "accepts logs at or above configured level", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, item_header, item_body, _] = String.split(body, "\n")

        item_header_map = decode!(item_header)
        assert item_header_map["type"] == "log"
        assert item_header_map["item_count"] == 3

        item_body_map = decode!(item_body)
        assert %{"items" => log_events} = item_body_map
        assert length(log_events) == 3

        assert [info_event, warning_event, error_event] = log_events
        assert info_event["level"] == "info"
        assert info_event["body"] == "Info message"
        assert warning_event["level"] == "warn"
        assert warning_event["body"] == "Warning message"
        assert error_event["level"] == "error"
        assert error_event["body"] == "Error message"

        send(test_pid, :envelope_sent)

        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      initial_size = TelemetryProcessor.buffer_size(:log)

      Logger.info("Info message")
      Logger.warning("Warning message")
      Logger.error("Error message")

      assert_buffer_size(nil, initial_size + 3)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
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

    test "includes metadata as attributes", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, item_header, item_body, _] = String.split(body, "\n")

        item_header_map = decode!(item_header)
        assert item_header_map["type"] == "log"
        assert item_header_map["item_count"] == 1

        item_body_map = decode!(item_body)
        assert %{"items" => [log_event]} = item_body_map
        assert log_event["body"] == "Request processed"

        assert %{"request_id" => %{"type" => "string", "value" => "abc123"}} =
                 log_event["attributes"]

        assert %{"user_id" => %{"type" => "integer", "value" => 42}} = log_event["attributes"]

        refute Map.has_key?(log_event["attributes"], "other_meta")

        send(test_pid, :envelope_sent)

        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      put_test_config(logs: [metadata: [:request_id, :user_id]])

      TelemetryProcessor.flush()

      Logger.metadata(request_id: "abc123", user_id: 42, other_meta: "should not be included")
      Logger.info("Request processed")

      assert_buffer_size(nil, 1)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "includes all metadata when configured with :all" do
      put_test_config(logs: [metadata: :all])

      TelemetryProcessor.flush()

      Logger.metadata(request_id: "abc123", user_id: 42, custom_field: "value")
      Logger.info("Request with metadata")

      assert_buffer_size(nil, 1)
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

    test "generates trace_id when no trace context is available", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, _item_header, item_body, _] = String.split(body, "\n")

        item_body_map = decode!(item_body)
        assert %{"items" => [log_event]} = item_body_map
        assert log_event["body"] == "Log without trace"

        assert is_binary(log_event["trace_id"])
        assert String.length(log_event["trace_id"]) == 32
        assert String.match?(log_event["trace_id"], ~r/^[0-9a-f]{32}$/)

        refute Map.has_key?(log_event["attributes"], "sentry.trace.parent_span_id")

        send(test_pid, :envelope_sent)

        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      TelemetryProcessor.flush()

      Logger.info("Log without trace")

      assert_buffer_size(nil, 1)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "captures message template with %s parameters via Logger metadata", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, _item_header, item_body, _] = String.split(body, "\n")

        item_body_map = decode!(item_body)
        assert %{"items" => [log_event]} = item_body_map

        # The body should be the interpolated message
        assert log_event["body"] == "User jane_doe logged in from 192.168.1.1"

        # Check for template attribute
        assert %{
                 "sentry.message.template" => %{
                   "type" => "string",
                   "value" => "User %s logged in from %s"
                 }
               } = log_event["attributes"]

        # Check for parameter attributes
        assert %{
                 "sentry.message.parameter.0" => %{
                   "type" => "string",
                   "value" => "jane_doe"
                 }
               } = log_event["attributes"]

        assert %{
                 "sentry.message.parameter.1" => %{
                   "type" => "string",
                   "value" => "192.168.1.1"
                 }
               } = log_event["attributes"]

        send(test_pid, :envelope_sent)

        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      TelemetryProcessor.flush()

      # Use Logger with %s template and parameters via metadata
      Logger.info("User %s logged in from %s", parameters: ["jane_doe", "192.168.1.1"])

      assert_buffer_size(nil, 1)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "captures message template with %{key} named parameters", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, _item_header, item_body, _] = String.split(body, "\n")

        item_body_map = decode!(item_body)
        assert %{"items" => [log_event]} = item_body_map

        # The body should be the interpolated message
        assert log_event["body"] == "Hello Jane from NYC"

        # Check for template attribute
        assert %{
                 "sentry.message.template" => %{
                   "type" => "string",
                   "value" => "Hello %{name} from %{city}"
                 }
               } = log_event["attributes"]

        # Parameters are stored in template order
        assert %{
                 "sentry.message.parameter.0" => %{
                   "type" => "string",
                   "value" => "Jane"
                 }
               } = log_event["attributes"]

        assert %{
                 "sentry.message.parameter.1" => %{
                   "type" => "string",
                   "value" => "NYC"
                 }
               } = log_event["attributes"]

        send(test_pid, :envelope_sent)

        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      TelemetryProcessor.flush()

      # Use Logger with %{key} template and named parameters
      Logger.info("Hello %{name} from %{city}", parameters: %{name: "Jane", city: "NYC"})

      assert_buffer_size(nil, 1)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "does not include template attributes for plain string messages", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, _item_header, item_body, _] = String.split(body, "\n")

        item_body_map = decode!(item_body)
        assert %{"items" => [log_event]} = item_body_map

        assert log_event["body"] == "Simple log message"

        # Should NOT have template or parameter attributes
        refute Map.has_key?(log_event["attributes"], "sentry.message.template")
        refute Map.has_key?(log_event["attributes"], "sentry.message.parameter.0")

        send(test_pid, :envelope_sent)

        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      TelemetryProcessor.flush()

      Logger.info("Simple log message")

      assert_buffer_size(nil, 1)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
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

    test "automatically includes trace context from OpenTelemetry spans", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, item_header, item_body, _] = String.split(body, "\n")

        item_header_map = decode!(item_header)

        case item_header_map["type"] do
          "log" ->
            assert item_header_map["item_count"] == 1

            item_body_map = decode!(item_body)
            assert %{"items" => [log_event]} = item_body_map
            assert log_event["body"] == "Log inside OTel span"

            assert is_binary(log_event["trace_id"])
            assert String.length(log_event["trace_id"]) == 32
            assert String.match?(log_event["trace_id"], ~r/^[0-9a-f]{32}$/)

            span_id = log_event["span_id"]
            assert is_binary(span_id)
            assert String.length(span_id) == 16
            assert String.match?(span_id, ~r/^[0-9a-f]{16}$/)

            send(test_pid, :envelope_sent)

            Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)

          "transaction" ->
            Plug.Conn.resp(conn, 200, ~s<{"id": "test-txn"}>)
        end
      end)

      TelemetryProcessor.flush()

      Tracer.with_span "test_span" do
        Logger.info("Log inside OTel span")
      end

      assert_buffer_size(nil, 1)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "includes trace context from nested OpenTelemetry spans", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, item_header, item_body, _] = String.split(body, "\n")

        item_header_map = decode!(item_header)

        case item_header_map["type"] do
          "log" ->
            assert item_header_map["item_count"] == 2

            item_body_map = decode!(item_body)
            assert %{"items" => log_events} = item_body_map
            assert length(log_events) == 2

            [parent_log, child_log] = log_events

            assert parent_log["trace_id"] == child_log["trace_id"]

            parent_span_id = parent_log["span_id"]
            child_span_id = child_log["span_id"]

            assert is_binary(parent_span_id)
            assert is_binary(child_span_id)
            assert parent_span_id != child_span_id

            send(test_pid, :envelope_sent)

            Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)

          "transaction" ->
            Plug.Conn.resp(conn, 200, ~s<{"id": "test-txn"}>)
        end
      end)

      TelemetryProcessor.flush()

      require OpenTelemetry.Tracer, as: Tracer

      Tracer.with_span "parent_span" do
        Logger.info("Log in parent span")

        Tracer.with_span "child_span" do
          Logger.info("Log in child span")
        end
      end

      assert_buffer_size(nil, 2)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "works out-of-the-box when handler is configured", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, item_header, item_body, _] = String.split(body, "\n")

        item_header_map = decode!(item_header)

        case item_header_map["type"] do
          "log" ->
            item_body_map = decode!(item_body)
            assert %{"items" => [log_event]} = item_body_map

            assert is_binary(log_event["trace_id"])
            assert String.length(log_event["trace_id"]) == 32

            assert is_binary(log_event["span_id"])

            send(test_pid, :envelope_sent)

            Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)

          "transaction" ->
            Plug.Conn.resp(conn, 200, ~s<{"id": "test-txn"}>)
        end
      end)

      TelemetryProcessor.flush()

      Tracer.with_span "api_call" do
        Logger.info("Processing API request")
      end

      assert_buffer_size(nil, 1)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end
  end

  describe "before_send_log callback" do
    test "allows modifying log events before sending", %{bypass: bypass} do
      test_pid = self()

      put_test_config(
        before_send_log: fn log_event ->
          %{log_event | attributes: Map.put(log_event.attributes, "custom_attr", "injected")}
        end
      )

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, _item_header, item_body, _] = String.split(body, "\n")

        item_body_map = decode!(item_body)
        assert %{"items" => [log_event]} = item_body_map

        assert log_event["attributes"]["custom_attr"] == %{
                 "type" => "string",
                 "value" => "injected"
               }

        send(test_pid, :envelope_sent)
        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      Logger.info("Test message")

      assert_buffer_size(nil, 1)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "filters out log events when callback returns nil", %{bypass: bypass} do
      put_test_config(
        before_send_log: fn log_event ->
          if String.contains?(log_event.body, "should_be_filtered") do
            nil
          else
            log_event
          end
        end
      )

      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, _item_header, item_body, _] = String.split(body, "\n")

        item_body_map = decode!(item_body)
        assert %{"items" => [log_event]} = item_body_map
        assert log_event["body"] == "This message should pass"

        send(test_pid, :envelope_sent)
        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      Logger.info("This message should_be_filtered")
      Logger.info("This message should pass")

      assert_buffer_size(nil, 2)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "filters out log events when callback returns false", %{bypass: bypass} do
      put_test_config(
        before_send_log: fn log_event ->
          if String.contains?(log_event.body, "drop_me") do
            false
          else
            log_event
          end
        end
      )

      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, _item_header, item_body, _] = String.split(body, "\n")

        item_body_map = decode!(item_body)
        assert %{"items" => [log_event]} = item_body_map
        assert log_event["body"] == "Keep this message"

        send(test_pid, :envelope_sent)
        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      Logger.info("drop_me please")
      Logger.info("Keep this message")

      assert_buffer_size(nil, 2)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "supports MFA tuple callback format", %{bypass: bypass} do
      test_pid = self()

      put_test_config(before_send_log: {__MODULE__, :before_send_log_callback})

      Bypass.expect_once(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_header, _item_header, item_body, _] = String.split(body, "\n")

        item_body_map = decode!(item_body)
        assert %{"items" => [log_event]} = item_body_map

        assert log_event["attributes"]["mfa_added"] == %{
                 "type" => "string",
                 "value" => "true"
               }

        send(test_pid, :envelope_sent)
        Plug.Conn.resp(conn, 200, ~s<{"id": "test-123"}>)
      end)

      Logger.info("Test MFA callback")

      assert_buffer_size(nil, 1)

      TelemetryProcessor.flush()

      assert_receive :envelope_sent, 1000
    end

    test "does not send any logs when all are filtered", %{} do
      put_test_config(before_send_log: fn _log_event -> nil end)

      Logger.info("All messages filtered 1")
      Logger.info("All messages filtered 2")

      assert_buffer_size(nil, 2)

      TelemetryProcessor.flush()

      refute_receive _, 100
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
