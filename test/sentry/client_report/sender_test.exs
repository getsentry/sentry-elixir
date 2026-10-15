defmodule Sentry.ClientReportTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.ClientReport.Sender
  alias Sentry.{Envelope, Event, LogBatch, LogEvent, Metric, MetricBatch}

  setup do
    setup_bypass()
  end

  @span_id Sentry.UUID.uuid4_hex()

  describe "record_discarded_events/2 + flushing" do
    test "succefully records the discarded event to the client report", %{bypass: bypass} do
      sender_opts = [
        name: :test_client_report,
        rate_limiter_table_name: Process.get(:rate_limiter_table_name)
      ]

      start_supervised!({Sender, sender_opts})

      events = [
        %Event{
          event_id: Sentry.UUID.uuid4_hex(),
          timestamp: "2024-10-12T13:21:13"
        },
        create_transaction(%{
          transaction: "test-transaction",
          spans: [
            create_span(%{
              span_id: @span_id,
              trace_id: Sentry.UUID.uuid4_hex(),
              start_timestamp: "2024-10-12T13:21:13",
              timestamp: "2024-10-12T13:21:13"
            })
          ]
        })
      ]

      assert :ok = Sender.record_discarded_events(:before_send, events, :test_client_report)

      # The transaction has a single span, so the "span" outcome is 1 + 1 = 2
      # (the extra span accounts for the transaction itself).
      assert :sys.get_state(:test_client_report) == %{
               {:before_send, "error"} => 1,
               {:before_send, "transaction"} => 1,
               {:before_send, "span"} => 2
             }

      assert :ok = Sender.record_discarded_events(:before_send, events, :test_client_report)

      assert :sys.get_state(:test_client_report) == %{
               {:before_send, "error"} => 2,
               {:before_send, "transaction"} => 2,
               {:before_send, "span"} => 4
             }

      assert :ok = Sender.record_discarded_events(:event_processor, events, :test_client_report)
      assert :ok = Sender.record_discarded_events(:network_error, events, :test_client_report)

      assert :sys.get_state(:test_client_report) == %{
               {:before_send, "error"} => 2,
               {:before_send, "transaction"} => 2,
               {:before_send, "span"} => 4,
               {:event_processor, "error"} => 1,
               {:event_processor, "transaction"} => 1,
               {:event_processor, "span"} => 2,
               {:network_error, "error"} => 1,
               {:network_error, "transaction"} => 1,
               {:network_error, "span"} => 2
             }

      send(Process.whereis(:test_client_report), :send_report)

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert [{%{"type" => "client_report", "length" => _}, client_report}] =
                 decode_envelope!(body)

        assert client_report["discarded_events"] == [
                 %{"category" => "error", "quantity" => 2, "reason" => "before_send"},
                 %{"category" => "span", "quantity" => 4, "reason" => "before_send"},
                 %{"category" => "transaction", "quantity" => 2, "reason" => "before_send"},
                 %{"category" => "error", "quantity" => 1, "reason" => "event_processor"},
                 %{"category" => "span", "quantity" => 2, "reason" => "event_processor"},
                 %{"category" => "transaction", "quantity" => 1, "reason" => "event_processor"},
                 %{"category" => "error", "quantity" => 1, "reason" => "network_error"},
                 %{"category" => "span", "quantity" => 2, "reason" => "network_error"},
                 %{"category" => "transaction", "quantity" => 1, "reason" => "network_error"}
               ]

        assert client_report["timestamp"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      assert :sys.get_state(:test_client_report) == %{}
    end

    test "records a span outcome of spans + 1 when a transaction is discarded" do
      start_supervised!({Sender, name: :test_span_report})

      # A transaction with 3 spans -> span outcome of 3 + 1 = 4.
      transaction =
        create_transaction(%{
          transaction: "multi-span",
          spans:
            for _ <- 1..3 do
              create_span(%{span_id: Sentry.UUID.uuid4_hex()})
            end
        })

      assert :ok =
               Sender.record_discarded_events(:before_send, [transaction], :test_span_report)

      assert :sys.get_state(:test_span_report) == %{
               {:before_send, "transaction"} => 1,
               {:before_send, "span"} => 4
             }
    end

    test "records a span outcome of 1 when a transaction with no spans is discarded" do
      start_supervised!({Sender, name: :test_empty_span_report})

      transaction = create_transaction(%{transaction: "no-spans", spans: []})

      assert :ok =
               Sender.record_discarded_events(
                 :before_send,
                 [transaction],
                 :test_empty_span_report
               )

      assert :sys.get_state(:test_empty_span_report) == %{
               {:before_send, "transaction"} => 1,
               {:before_send, "span"} => 1
             }
    end

    test "records both log_item and log_byte outcomes when a log event is discarded" do
      start_supervised!({Sender, name: :test_log_report})

      log_event = make_log_event("hello world")
      expected_bytes = Envelope.item_byte_size(log_event)
      assert expected_bytes > 0

      assert :ok =
               Sender.record_discarded_events(:ratelimit_backoff, [log_event], :test_log_report)

      assert :sys.get_state(:test_log_report) == %{
               {:ratelimit_backoff, "log_item"} => 1,
               {:ratelimit_backoff, "log_byte"} => expected_bytes
             }
    end

    test "records both trace_metric and trace_metric_byte outcomes when a metric is discarded" do
      start_supervised!({Sender, name: :test_metric_report})

      metric = make_metric("requests", 1)
      expected_bytes = Envelope.item_byte_size(metric)
      assert expected_bytes > 0

      assert :ok =
               Sender.record_discarded_events(:ratelimit_backoff, [metric], :test_metric_report)

      assert :sys.get_state(:test_metric_report) == %{
               {:ratelimit_backoff, "trace_metric"} => 1,
               {:ratelimit_backoff, "trace_metric_byte"} => expected_bytes
             }
    end

    test "records aggregate log_item and log_byte outcomes when a log batch is discarded" do
      start_supervised!({Sender, name: :test_log_batch_report})

      log_events = [make_log_event("first"), make_log_event("second")]
      expected_bytes = Enum.reduce(log_events, 0, &(Envelope.item_byte_size(&1) + &2))
      assert expected_bytes > 0
      log_batch = %LogBatch{log_events: log_events}

      assert :ok =
               Sender.record_discarded_events(:send_error, [log_batch], :test_log_batch_report)

      assert :sys.get_state(:test_log_batch_report) == %{
               {:send_error, "log_item"} => 2,
               {:send_error, "log_byte"} => expected_bytes
             }
    end

    test "records aggregate trace_metric and trace_metric_byte outcomes when a metric batch is discarded" do
      start_supervised!({Sender, name: :test_metric_batch_report})

      metrics = [make_metric("a", 1), make_metric("b", 2)]
      expected_bytes = Enum.reduce(metrics, 0, &(Envelope.item_byte_size(&1) + &2))
      assert expected_bytes > 0
      metric_batch = %MetricBatch{metrics: metrics}

      assert :ok =
               Sender.record_discarded_events(
                 :send_error,
                 [metric_batch],
                 :test_metric_batch_report
               )

      assert :sys.get_state(:test_metric_batch_report) == %{
               {:send_error, "trace_metric"} => 2,
               {:send_error, "trace_metric_byte"} => expected_bytes
             }
    end

    test "does not record zero-quantity outcomes for an empty batch" do
      start_supervised!({Sender, name: :test_empty_batch_report})

      assert :ok =
               Sender.record_discarded_events(
                 :send_error,
                 [%LogBatch{log_events: []}, %MetricBatch{metrics: []}],
                 :test_empty_batch_report
               )

      assert :sys.get_state(:test_empty_batch_report) == %{}
    end

    test "expands items into outcomes inside the Sender, not on the calling process" do
      start_supervised!({Sender, name: :test_encoding_process_report})
      put_test_config(json_library: ReportingJSONLibrary)

      ReportingJSONLibrary.report_to(self())
      sender = Process.whereis(:test_encoding_process_report)

      assert :ok =
               Sender.record_discarded_events(
                 :ratelimit_backoff,
                 [make_log_event("hello world")],
                 :test_encoding_process_report
               )

      # Flush the cast so the encode has definitely happened by now.
      _ = :sys.get_state(:test_encoding_process_report)

      assert_received {:encoded, encoding_pid}
      assert encoding_pid == sender
    end

    test "keeps discard counts when the client report post fails", %{bypass: bypass} do
      sender = start_sender(:test_client_report_post_failure)
      event = make_error_event()

      assert :ok = Sender.record_discarded_events(:before_send, [event], sender)
      assert :sys.get_state(sender) == %{{:before_send, "error"} => 1}

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 503, ~s<{"detail":"unavailable"}>)
      end)

      send(Process.whereis(sender), :send_report)

      # Sentry never accepted this window, so the count must still be accumulated.
      assert :sys.get_state(sender) == %{{:before_send, "error"} => 1}

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert [{%{"type" => "client_report", "length" => _}, client_report}] =
                 decode_envelope!(body)

        assert client_report["discarded_events"] == [
                 %{"category" => "error", "quantity" => 1, "reason" => "before_send"}
               ]

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      send(Process.whereis(sender), :send_report)

      assert :sys.get_state(sender) == %{}
    end

    test "merges discards recorded while a failed client report post is in flight", %{
      bypass: bypass
    } do
      sender = start_sender(:test_client_report_inflight_failure)
      event = make_error_event()

      assert :ok = Sender.record_discarded_events(:before_send, [event], sender)

      self_pid = self()

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        Sender.record_discarded_events(:network_error, [event], sender)
        send(self_pid, :recorded_during_post)
        Plug.Conn.resp(conn, 503, ~s<{"detail":"unavailable"}>)
      end)

      send(Process.whereis(sender), :send_report)
      assert_receive :recorded_during_post

      assert :sys.get_state(sender) == %{
               {:before_send, "error"} => 1,
               {:network_error, "error"} => 1
             }

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert [{%{"type" => "client_report", "length" => _}, client_report}] =
                 decode_envelope!(body)

        assert Enum.sort(client_report["discarded_events"]) ==
                 Enum.sort([
                   %{"category" => "error", "quantity" => 1, "reason" => "before_send"},
                   %{"category" => "error", "quantity" => 1, "reason" => "network_error"}
                 ])

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      send(Process.whereis(sender), :send_report)

      assert :sys.get_state(sender) == %{}
    end

    test "flush keeps discard counts when the client report post fails", %{bypass: bypass} do
      sender = start_sender(:test_client_report_flush_failure)
      event = make_error_event()

      assert :ok = Sender.record_discarded_events(:before_send, [event], sender)

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 503, ~s<{"detail":"unavailable"}>)
      end)

      assert :ok = Sender.flush(sender)
      assert :sys.get_state(sender) == %{{:before_send, "error"} => 1}
    end

    test "keeps discard counts when the connection is refused", %{bypass: bypass} do
      sender = start_sender(:test_client_report_connrefused)
      event = make_error_event()

      assert :ok = Sender.record_discarded_events(:before_send, [event], sender)

      Bypass.down(bypass)

      assert :ok = Sender.flush(sender)
      assert :sys.get_state(sender) == %{{:before_send, "error"} => 1}
    end

    test "drops discard counts when the client report post times out", %{bypass: bypass} do
      sender = start_sender(:test_client_report_timeout)
      event = make_error_event()

      assert :ok = Sender.record_discarded_events(:before_send, [event], sender)

      # The handler never responds. A receive timeout is an unknown outcome:
      # the bytes may already have been stored, so the counts must not be retried.
      put_test_config(finch_request_opts: [receive_timeout: 50])

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn _conn ->
        Process.sleep(:infinity)
      end)

      try do
        assert :ok = Sender.flush(sender)
        assert :sys.get_state(sender) == %{}
      after
        Bypass.pass(bypass)
      end
    end
  end

  defp start_sender(name) do
    start_supervised!(
      {Sender, name: name, rate_limiter_table_name: Process.get(:rate_limiter_table_name)}
    )

    name
  end

  defp make_error_event do
    %Event{
      event_id: Sentry.UUID.uuid4_hex(),
      timestamp: "2024-10-12T13:21:13"
    }
  end

  defp make_log_event(body) do
    %LogEvent{
      timestamp: System.system_time(:nanosecond) / 1_000_000_000,
      level: :info,
      body: body
    }
  end

  defp make_metric(name, value) do
    %Metric{
      type: :counter,
      name: name,
      value: value,
      timestamp: System.system_time(:nanosecond) / 1_000_000_000,
      attributes: %{}
    }
  end
end
