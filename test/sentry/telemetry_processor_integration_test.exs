defmodule Sentry.TelemetryProcessorIntegrationTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  require Logger

  alias Sentry.TelemetryProcessor
  alias Sentry.Telemetry.Buffer
  alias Sentry.{LogEvent, Metric, Transaction}

  setup _context do
    %{bypass: bypass, telemetry_processor: name, ref: ref} =
      Sentry.Test.setup_sentry(
        collect_envelopes: true,
        telemetry_processor: [buffer_configs: %{log: %{batch_size: 1}}]
      )

    %{processor: name, ref: ref, bypass: bypass}
  end

  describe "error events with telemetry_processor_categories" do
    setup do
      put_test_config(telemetry_processor_categories: [:error, :log])
      :ok
    end

    test "buffers error events through TelemetryProcessor when opted in", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      Sentry.capture_message("integration test error", result: :none)

      error_buffer = TelemetryProcessor.get_buffer(ctx.processor, :error)
      assert Buffer.size(error_buffer) == 1

      :sys.resume(scheduler)

      envelopes = collect_envelopes(ctx.ref, 1, timeout: 2000)
      assert length(envelopes) == 1

      [[{%{"type" => "event"}, event}]] = envelopes
      assert event["message"]["formatted"] == "integration test error"
    end

    test "critical errors are not starved by high-volume log events", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      for _i <- 1..50 do
        TelemetryProcessor.add(ctx.processor, make_log_event("flood-log"))
      end

      for i <- 1..3 do
        Sentry.capture_message("critical-error-#{i}", result: :none)
      end

      error_buffer = TelemetryProcessor.get_buffer(ctx.processor, :error)
      log_buffer = TelemetryProcessor.get_buffer(ctx.processor, :log)
      assert Buffer.size(error_buffer) == 3
      assert Buffer.size(log_buffer) == 50

      :sys.resume(scheduler)

      envelopes = collect_envelopes(ctx.ref, 5, timeout: 2000)
      categories = Enum.map(envelopes, &decoded_envelope_category/1)

      error_count = Enum.count(categories, &(&1 == :error))
      assert error_count == 3

      first_three = Enum.take(categories, 3)
      assert first_three == [:error, :error, :error]
    end

    test "flush drains error buffer completely", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      for i <- 1..5 do
        Sentry.capture_message("flush-error-#{i}", result: :none)
      end

      error_buffer = TelemetryProcessor.get_buffer(ctx.processor, :error)
      assert Buffer.size(error_buffer) == 5

      :sys.resume(scheduler)
      :ok = TelemetryProcessor.flush(ctx.processor)

      assert Buffer.size(error_buffer) == 0

      envelopes = collect_envelopes(ctx.ref, 5, timeout: 2000)
      assert length(envelopes) == 5
      assert Enum.all?(envelopes, fn [{%{"type" => type}, _}] -> type == "event" end)
    end
  end

  describe "check-in events with telemetry_processor_categories" do
    setup do
      put_test_config(telemetry_processor_categories: [:check_in, :log])
      :ok
    end

    test "buffers check-in events through TelemetryProcessor when opted in", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      {:ok, _id} = Sentry.capture_check_in(status: :ok, monitor_slug: "test-job")

      check_in_buffer = TelemetryProcessor.get_buffer(ctx.processor, :check_in)
      assert Buffer.size(check_in_buffer) == 1

      :sys.resume(scheduler)

      envelopes = collect_envelopes(ctx.ref, 1, timeout: 2000)
      assert length(envelopes) == 1

      [[{%{"type" => "check_in"}, check_in}]] = envelopes
      assert check_in["monitor_slug"] == "test-job"
      assert check_in["status"] == "ok"
    end

    test "flush drains check-in buffer completely", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      for i <- 1..3 do
        {:ok, _id} = Sentry.capture_check_in(status: :ok, monitor_slug: "job-#{i}")
      end

      check_in_buffer = TelemetryProcessor.get_buffer(ctx.processor, :check_in)
      assert Buffer.size(check_in_buffer) == 3

      :sys.resume(scheduler)
      :ok = TelemetryProcessor.flush(ctx.processor)

      assert Buffer.size(check_in_buffer) == 0

      envelopes = collect_envelopes(ctx.ref, 3, timeout: 2000)
      assert length(envelopes) == 3
      assert Enum.all?(envelopes, fn [{%{"type" => type}, _}] -> type == "check_in" end)
    end
  end

  describe "transaction events with telemetry_processor_categories" do
    setup do
      put_test_config(telemetry_processor_categories: [:transaction, :log])
      :ok
    end

    test "buffers transaction events through TelemetryProcessor when opted in", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      transaction = make_transaction()
      TelemetryProcessor.add(ctx.processor, transaction)

      transaction_buffer = TelemetryProcessor.get_buffer(ctx.processor, :transaction)
      assert Buffer.size(transaction_buffer) == 1

      :sys.resume(scheduler)

      envelopes = collect_envelopes(ctx.ref, 1, timeout: 2000)
      assert length(envelopes) == 1

      [[{%{"type" => "transaction"}, transaction_data}]] = envelopes
      assert is_binary(transaction_data["event_id"])
      assert is_number(transaction_data["start_timestamp"])
      assert is_number(transaction_data["timestamp"])
    end

    test "flush drains transaction buffer completely", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      for _i <- 1..3 do
        TelemetryProcessor.add(ctx.processor, make_transaction())
      end

      transaction_buffer = TelemetryProcessor.get_buffer(ctx.processor, :transaction)
      assert Buffer.size(transaction_buffer) == 3

      :sys.resume(scheduler)
      :ok = TelemetryProcessor.flush(ctx.processor)

      assert Buffer.size(transaction_buffer) == 0

      envelopes = collect_envelopes(ctx.ref, 3, timeout: 2000)
      assert length(envelopes) == 3
      assert Enum.all?(envelopes, fn [{%{"type" => type}, _}] -> type == "transaction" end)
    end
  end

  describe "log batching" do
    test "sends log events as batched envelopes", ctx do
      TelemetryProcessor.add(ctx.processor, make_log_event("log-1"))
      TelemetryProcessor.add(ctx.processor, make_log_event("log-2"))

      envelopes = collect_envelopes(ctx.ref, 2, timeout: 2000)
      assert length(envelopes) == 2

      for [{header, payload}] <- envelopes do
        assert header["type"] == "log"
        assert %{"items" => [%{"body" => _}]} = payload
      end
    end

    test "flush drains log buffer completely", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      TelemetryProcessor.add(ctx.processor, make_log_event("flush-1"))
      TelemetryProcessor.add(ctx.processor, make_log_event("flush-2"))
      TelemetryProcessor.add(ctx.processor, make_log_event("flush-3"))

      buffer = TelemetryProcessor.get_buffer(ctx.processor, :log)
      assert Buffer.size(buffer) == 3

      :sys.resume(scheduler)
      :ok = TelemetryProcessor.flush(ctx.processor)

      assert Buffer.size(buffer) == 0

      envelopes = collect_envelopes(ctx.ref, 3, timeout: 2000)
      assert length(envelopes) == 3
    end

    test "applies before_send_log callback", ctx do
      put_test_config(
        before_send_log: fn log_event ->
          if log_event.body == "drop me", do: nil, else: log_event
        end
      )

      TelemetryProcessor.add(ctx.processor, make_log_event("keep me"))
      TelemetryProcessor.add(ctx.processor, make_log_event("drop me"))

      envelopes = collect_envelopes(ctx.ref, 1, timeout: 2000)
      assert length(envelopes) == 1

      [[{%{"type" => "log"}, %{"items" => [%{"body" => "keep me"}]}}]] = envelopes

      # The dropped event should not produce an envelope
      ref = ctx.ref
      refute_receive {:bypass_envelope, ^ref, _body}, 200
    end
  end

  describe "buffer overflow client reports" do
    setup ctx do
      Sentry.Test.setup_telemetry_processor(
        buffer_configs: %{
          log: %{capacity: 2, batch_size: 1},
          metric: %{capacity: 2, batch_size: 1}
        }
      )

      flush_ref_messages(ctx.ref)

      :ok
    end

    test "sends cache_overflow client report when log buffer overflows", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      # The evicted (oldest) event is deliberately much larger than the ones that
      # stay, so reporting the wrong item fails loudly instead of by a byte or two.
      dropped_log = make_log_event(String.duplicate("x", 500))
      TelemetryProcessor.add(ctx.processor, dropped_log)
      TelemetryProcessor.add(ctx.processor, make_log_event("log-2"))
      TelemetryProcessor.add(ctx.processor, make_log_event("log-3"))

      _ = Buffer.size(TelemetryProcessor.get_buffer(ctx.processor, :log))

      Sentry.ClientReport.Sender.flush()

      ref = ctx.ref
      assert_receive {:bypass_envelope, ^ref, body}, 2000

      items = decode_envelope!(body)
      assert [{%{"type" => "client_report"}, client_report}] = items

      discarded = client_report["discarded_events"]

      log_item =
        Enum.find(discarded, &(&1["reason"] == "cache_overflow" and &1["category"] == "log_item"))

      log_byte =
        Enum.find(discarded, &(&1["reason"] == "cache_overflow" and &1["category"] == "log_byte"))

      assert log_item["quantity"] == 1
      assert log_byte["quantity"] == Sentry.Envelope.item_byte_size(dropped_log)

      :sys.resume(scheduler)
    end

    test "sends trace_metric and trace_metric_byte reports when metric buffer overflows", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      dropped_metric = make_metric(String.duplicate("m", 500), 1)
      TelemetryProcessor.add(ctx.processor, dropped_metric)
      TelemetryProcessor.add(ctx.processor, make_metric("metric-2", 2))
      TelemetryProcessor.add(ctx.processor, make_metric("metric-3", 3))

      _ = Buffer.size(TelemetryProcessor.get_buffer(ctx.processor, :metric))

      Sentry.ClientReport.Sender.flush()

      ref = ctx.ref
      assert_receive {:bypass_envelope, ^ref, body}, 2000

      assert [{%{"type" => "client_report"}, client_report}] = decode_envelope!(body)
      discarded = client_report["discarded_events"]

      trace_metric =
        Enum.find(
          discarded,
          &(&1["reason"] == "cache_overflow" and &1["category"] == "trace_metric")
        )

      trace_metric_byte =
        Enum.find(
          discarded,
          &(&1["reason"] == "cache_overflow" and &1["category"] == "trace_metric_byte")
        )

      assert trace_metric["quantity"] == 1
      assert trace_metric_byte["quantity"] == Sentry.Envelope.item_byte_size(dropped_metric)

      :sys.resume(scheduler)
    end
  end

  describe "scheduler rate limiting" do
    setup ctx do
      put_test_config(telemetry_processor_categories: [:error, :check_in, :transaction, :log])

      Bypass.stub(ctx.bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      on_exit(fn -> reset_rate_limits(scope: :scheduler) end)

      :ok
    end

    test "rate-limited HTTP response causes subsequent events to be dropped with client report",
         ctx do
      put_test_config(client: Sentry.FinchClient)

      ref = install_rate_limit_response(ctx.bypass, "error")

      Sentry.capture_message("first-error", result: :none)

      assert_receive {:bypass_envelope, ^ref, body}, 2000
      assert [{%{"type" => "event"}, event}] = decode_envelope!(body)
      assert event["message"]["formatted"] == "first-error"

      wait_for_scheduler_idle(ctx.processor)

      Sentry.capture_message("rate-limited-error", result: :none)

      outcomes = collect_discarded_outcomes(ctx.client_report_sender, ref, "ratelimit_backoff")

      assert outcomes["error"] == 1
    end
  end

  # The queue-worker process applies the response header to the *global* rate
  # limiter table, while producers read this test's isolated one — so items still
  # enter the buffer here and are dropped later, when the scheduler drains it.
  describe "byte-based rate limits returned by Sentry" do
    setup ctx do
      Sentry.Test.setup_telemetry_processor(
        buffer_configs: %{log: %{batch_size: 1}, metric: %{batch_size: 1}}
      )

      put_test_config(client: Sentry.FinchClient)
      flush_ref_messages(ctx.ref)

      on_exit(fn -> reset_rate_limits(scope: :scheduler) end)

      :ok
    end

    test "a trace_metric_byte limit stops further metrics and reports paired outcomes", ctx do
      put_test_config(enable_metrics: true)

      ref = install_rate_limit_response(ctx.bypass, "trace_metric_byte")

      Sentry.Metrics.count("first.metric", 1)
      assert_receive {:bypass_envelope, ^ref, _body}, 5000

      wait_for_scheduler_idle(ctx.processor)

      Sentry.Metrics.count("rate.limited.metric", 1)

      outcomes = collect_discarded_outcomes(ctx.client_report_sender, ref, "ratelimit_backoff")

      assert outcomes["trace_metric"] == 1
      assert is_integer(outcomes["trace_metric_byte"]) and outcomes["trace_metric_byte"] > 0
    end

    @tag :capture_log
    test "a log_byte limit stops further logs and reports paired outcomes", ctx do
      put_test_config(enable_logs: true, logs: [level: :info])
      attach_sentry_logs_handler()

      ref = install_rate_limit_response(ctx.bypass, "log_byte")

      Logger.info("first log")
      assert_receive {:bypass_envelope, ^ref, _body}, 5000

      wait_for_scheduler_idle(ctx.processor)

      Logger.info("rate limited log")

      outcomes = collect_discarded_outcomes(ctx.client_report_sender, ref, "ratelimit_backoff")

      assert outcomes["log_item"] == 1
      assert is_integer(outcomes["log_byte"]) and outcomes["log_byte"] > 0
    end
  end

  describe "pre-buffer rate limit checks" do
    setup ctx do
      flush_ref_messages(ctx.ref)

      :ok
    end

    test "drops rate-limited log events before they enter the buffer", ctx do
      Bypass.stub(ctx.bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      log_buffer = TelemetryProcessor.get_buffer(ctx.processor, :log)

      set_rate_limit("log_item")

      assert {:ok, {:rate_limited, "log_item"}} =
               TelemetryProcessor.add(ctx.processor, make_log_event("pre-buffer-drop"))

      assert Buffer.size(log_buffer) == 0
    end

    test "drops rate-limited error events before they enter the buffer", ctx do
      put_test_config(telemetry_processor_categories: [:error, :log])

      error_buffer = TelemetryProcessor.get_buffer(ctx.processor, :error)

      set_rate_limit("error")

      Sentry.capture_message("pre-buffer-drop", result: :none)

      assert Buffer.size(error_buffer) == 0

      Sentry.ClientReport.Sender.flush()

      ref = ctx.ref
      assert_receive {:bypass_envelope, ^ref, body}, 2000

      items = decode_envelope!(body)
      assert [{%{"type" => "client_report"}, client_report}] = items

      ratelimit_event =
        Enum.find(client_report["discarded_events"], &(&1["reason"] == "ratelimit_backoff"))

      assert ratelimit_event != nil
      assert ratelimit_event["category"] == "error"
      assert ratelimit_event["quantity"] == 1
    end

    test "records attachments when a global limit drops an error before buffering", ctx do
      put_test_config(telemetry_processor_categories: [:error, :log])

      error_buffer = TelemetryProcessor.get_buffer(ctx.processor, :error)

      set_rate_limit(:global)

      :ok =
        Sentry.Context.add_attachment(%Sentry.Attachment{filename: "report.txt", data: "report"})

      on_exit(&Sentry.Context.clear_attachments/0)

      Sentry.capture_message("pre-buffer-global-limit", result: :none)

      assert Buffer.size(error_buffer) == 0

      reset_rate_limits()

      assert collect_discarded_outcomes(ctx.client_report_sender, ctx.ref, "ratelimit_backoff") ==
               %{
                 "attachment" => 1,
                 "error" => 1
               }
    end

    test "sends an error without attachments when attachments are rate limited", ctx do
      put_test_config(telemetry_processor_categories: [:error, :log])

      set_rate_limit("attachment", scope: :scheduler)

      :ok =
        Sentry.Context.add_attachment(%Sentry.Attachment{filename: "report.txt", data: "report"})

      on_exit(&Sentry.Context.clear_attachments/0)

      Sentry.capture_message("pre-buffer-attachment-limit", result: :none)

      assert [[{%{"type" => "event"}, event}]] = collect_envelopes(ctx.ref, 1, timeout: 2000)
      assert event["message"]["formatted"] == "pre-buffer-attachment-limit"

      assert collect_discarded_outcomes(ctx.client_report_sender, ctx.ref, "ratelimit_backoff") ==
               %{
                 "attachment" => 1
               }
    end

    test "sends an error without attachments when attachment items are rate limited", ctx do
      put_test_config(telemetry_processor_categories: [:error, :log])

      set_rate_limit("attachment_item", scope: :scheduler)

      :ok =
        Sentry.Context.add_attachment(%Sentry.Attachment{filename: "report.txt", data: "report"})

      on_exit(&Sentry.Context.clear_attachments/0)

      Sentry.capture_message("pre-buffer-attachment-item-limit", result: :none)

      assert [[{%{"type" => "event"}, event}]] = collect_envelopes(ctx.ref, 1, timeout: 2000)
      assert event["message"]["formatted"] == "pre-buffer-attachment-item-limit"

      assert collect_discarded_outcomes(ctx.client_report_sender, ctx.ref, "ratelimit_backoff") ==
               %{
                 "attachment" => 1
               }
    end

    test "sends an error while dropping all of its rate-limited attachments", ctx do
      put_test_config(telemetry_processor_categories: [:error, :log])

      set_rate_limit("attachment", scope: :scheduler)

      :ok =
        Sentry.Context.add_attachment(%Sentry.Attachment{filename: "first.txt", data: "first"})

      :ok =
        Sentry.Context.add_attachment(%Sentry.Attachment{filename: "second.txt", data: "second"})

      on_exit(&Sentry.Context.clear_attachments/0)

      Sentry.capture_message("pre-buffer-multiple-attachment-limit", result: :none)

      assert [[{%{"type" => "event"}, event}]] = collect_envelopes(ctx.ref, 1, timeout: 2000)
      assert event["message"]["formatted"] == "pre-buffer-multiple-attachment-limit"

      assert collect_discarded_outcomes(ctx.client_report_sender, ctx.ref, "ratelimit_backoff") ==
               %{
                 "attachment" => 2
               }
    end

    test "drops rate-limited check-in events before they enter the buffer", ctx do
      put_test_config(telemetry_processor_categories: [:check_in, :log])

      check_in_buffer = TelemetryProcessor.get_buffer(ctx.processor, :check_in)

      set_rate_limit("monitor")

      {:ok, _id} = Sentry.capture_check_in(status: :ok, monitor_slug: "dropped-job")

      assert Buffer.size(check_in_buffer) == 0

      Sentry.ClientReport.Sender.flush()

      ref = ctx.ref
      assert_receive {:bypass_envelope, ^ref, body}, 2000

      items = decode_envelope!(body)
      assert [{%{"type" => "client_report"}, client_report}] = items

      ratelimit_event =
        Enum.find(client_report["discarded_events"], &(&1["reason"] == "ratelimit_backoff"))

      assert ratelimit_event != nil
      assert ratelimit_event["category"] == "monitor"
      assert ratelimit_event["quantity"] == 1
    end

    test "drops rate-limited transaction events before they enter the buffer", ctx do
      Bypass.stub(ctx.bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      put_test_config(telemetry_processor_categories: [:transaction, :log])

      transaction_buffer = TelemetryProcessor.get_buffer(ctx.processor, :transaction)

      set_rate_limit("transaction")

      assert {:ok, {:rate_limited, "transaction"}} =
               TelemetryProcessor.add(ctx.processor, make_transaction())

      assert Buffer.size(transaction_buffer) == 0
    end

    test "drops rate-limited metric events before they enter the buffer", ctx do
      Bypass.stub(ctx.bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      put_test_config(telemetry_processor_categories: [])

      metric_buffer = TelemetryProcessor.get_buffer(ctx.processor, :metric)

      set_rate_limit("trace_metric")

      assert {:ok, {:rate_limited, "trace_metric"}} =
               TelemetryProcessor.add(ctx.processor, make_metric("pre-buffer-drop", 1))

      assert Buffer.size(metric_buffer) == 0
    end

    # These drive the public APIs rather than `TelemetryProcessor.add/2` because
    # the paired byte outcome is recorded by `add/2`'s caller, which runs in the
    # emitting process and so reads this test's isolated rate limiter table.
    @tag :capture_log
    test "a log_byte rate limit drops logs emitted via Logger with paired outcomes", ctx do
      put_test_config(enable_logs: true, logs: [level: :info])
      attach_sentry_logs_handler()

      log_buffer = TelemetryProcessor.get_buffer(ctx.processor, :log)

      set_rate_limit("log_byte")

      Logger.info("dropped by a log_byte limit")

      assert Buffer.size(log_buffer) == 0

      outcomes =
        collect_discarded_outcomes(ctx.client_report_sender, ctx.ref, "ratelimit_backoff")

      assert outcomes["log_item"] == 1
      assert is_integer(outcomes["log_byte"]) and outcomes["log_byte"] > 0
    end

    test "a trace_metric_byte rate limit drops metrics emitted via Sentry.Metrics with paired outcomes",
         ctx do
      put_test_config(enable_metrics: true)

      metric_buffer = TelemetryProcessor.get_buffer(ctx.processor, :metric)

      set_rate_limit("trace_metric_byte")

      Sentry.Metrics.count("dropped.by.byte.limit", 1)

      assert Buffer.size(metric_buffer) == 0

      outcomes =
        collect_discarded_outcomes(ctx.client_report_sender, ctx.ref, "ratelimit_backoff")

      assert outcomes["trace_metric"] == 1
      assert is_integer(outcomes["trace_metric_byte"]) and outcomes["trace_metric_byte"] > 0
    end
  end

  describe "scheduler draining a rate-limited buffer" do
    setup ctx do
      put_test_config(telemetry_processor_categories: [:transaction, :log])
      flush_ref_messages(ctx.ref)

      :ok
    end

    test "records span outcomes when a buffered transaction is dropped by rate limiting", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      transaction_buffer = TelemetryProcessor.get_buffer(ctx.processor, :transaction)

      # Buffer a transaction with two spans *before* the category becomes
      # rate-limited, so it reaches the scheduler's drain path (not the
      # pre-buffer rate limit check).
      :sys.suspend(scheduler)

      transaction = %{make_transaction() | spans: [create_span(), create_span()]}
      TelemetryProcessor.add(ctx.processor, transaction)
      assert Buffer.size(transaction_buffer) == 1

      set_rate_limit("transaction", scope: :scheduler)

      :sys.resume(scheduler)
      GenServer.cast(scheduler, :signal)

      poll_until(fn -> Buffer.size(transaction_buffer) == 0 end)

      Sentry.ClientReport.Sender.flush()

      ref = ctx.ref
      assert_receive {:bypass_envelope, ^ref, body}, 2000
      assert [{%{"type" => "client_report"}, client_report}] = decode_envelope!(body)

      outcomes =
        for event <- client_report["discarded_events"],
            event["reason"] == "ratelimit_backoff",
            into: %{},
            do: {event["category"], event["quantity"]}

      # The transaction itself plus a "span" outcome of 2 spans + 1 = 3.
      assert outcomes["transaction"] == 1
      assert outcomes["span"] == 3
    end

    test "records log_item and log_byte outcomes when a buffered log is dropped by rate limiting",
         ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      log_buffer = TelemetryProcessor.get_buffer(ctx.processor, :log)

      :sys.suspend(scheduler)

      dropped_log = make_log_event("rate-limited-log")
      TelemetryProcessor.add(ctx.processor, dropped_log)
      assert Buffer.size(log_buffer) == 1

      set_rate_limit("log_item", scope: :scheduler)

      :sys.resume(scheduler)
      GenServer.cast(scheduler, :signal)

      poll_until(fn -> Buffer.size(log_buffer) == 0 end)

      Sentry.ClientReport.Sender.flush()

      ref = ctx.ref
      assert_receive {:bypass_envelope, ^ref, body}, 2000
      assert [{%{"type" => "client_report"}, client_report}] = decode_envelope!(body)

      outcomes =
        for event <- client_report["discarded_events"],
            event["reason"] == "ratelimit_backoff",
            into: %{},
            do: {event["category"], event["quantity"]}

      assert outcomes["log_item"] == 1
      assert outcomes["log_byte"] == Sentry.Envelope.item_byte_size(dropped_log)
    end
  end

  defp install_rate_limit_response(bypass, category) do
    test_pid = self()
    ref = make_ref()
    request_count = :counters.new(1, [])

    Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
      count = :counters.get(request_count, 1)
      :counters.add(request_count, 1, 1)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:bypass_envelope, ref, body})

      if count == 0 do
        conn
        |> Plug.Conn.put_resp_header("X-Sentry-Rate-Limits", "60:#{category}:organization")
        |> Plug.Conn.resp(200, ~s<{"id": "340"}>)
      else
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end
    end)

    ref
  end

  defp wait_for_scheduler_idle(processor) do
    scheduler = TelemetryProcessor.get_scheduler(processor)

    poll_until(fn ->
      %{active_ref: active_ref} = :sys.get_state(scheduler)
      is_nil(active_ref)
    end)
  end

  defp make_transaction(opts \\ []) do
    now = System.system_time(:microsecond)

    %Transaction{
      event_id: Sentry.UUID.uuid4_hex(),
      span_id: Sentry.UUID.uuid4_hex() |> binary_part(0, 16),
      start_timestamp: (now - 1_000_000) / 1_000_000,
      timestamp: now / 1_000_000,
      spans: Keyword.get(opts, :spans, [])
    }
  end

  # Outcomes are recorded with a cast from whichever process dropped the item, so
  # wait for the Sender to have something to report before flushing — an empty
  # buffer is not enough, since items are drained before the outcome is recorded.
  defp collect_discarded_outcomes(sender, ref, reason) do
    poll_until(fn -> :sys.get_state(sender) != %{} end)

    Sentry.ClientReport.Sender.flush(sender)

    for event <- await_client_report(ref)["discarded_events"],
        event["reason"] == reason,
        into: %{},
        do: {event["category"], event["quantity"]}
  end

  defp await_client_report(ref) do
    receive do
      {:bypass_envelope, ^ref, body} ->
        case decode_envelope!(body) do
          [{%{"type" => "client_report"}, client_report}] -> client_report
          _other -> await_client_report(ref)
        end
    after
      2000 -> flunk("no client report envelope received")
    end
  end

  defp flush_ref_messages(ref) do
    receive do
      {:bypass_envelope, ^ref, _body} -> flush_ref_messages(ref)
    after
      100 -> :ok
    end
  end

  defp decoded_envelope_category([{%{"type" => "event"}, _} | _]), do: :error
  defp decoded_envelope_category([{%{"type" => "check_in"}, _} | _]), do: :check_in
  defp decoded_envelope_category([{%{"type" => "transaction"}, _} | _]), do: :transaction
  defp decoded_envelope_category([{%{"type" => "log"}, _} | _]), do: :log

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

  defp attach_sentry_logs_handler do
    logs = Sentry.Config.logs()

    config = [
      enable_logs: true,
      capture_log_messages: Keyword.fetch!(logs, :capture_log_messages),
      capture_level: Keyword.fetch!(logs, :capture_level),
      capture_metadata: Keyword.fetch!(logs, :capture_metadata),
      capture_excluded_domains: Keyword.fetch!(logs, :capture_excluded_domains),
      logs_level: Keyword.fetch!(logs, :level),
      logs_metadata: Keyword.fetch!(logs, :metadata),
      logs_excluded_domains: Keyword.fetch!(logs, :excluded_domains)
    ]

    handler_name = :"sentry_logs_handler_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(handler_name, Sentry.LoggerHandler, %{config: config})
    on_exit(fn -> _ = :logger.remove_handler(handler_name) end)

    handler_name
  end

  defp poll_until(fun, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_until(fun, deadline)
  end

  defp do_poll_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "poll_until timed out"
      else
        Process.sleep(10)
        do_poll_until(fun, deadline)
      end
    end
  end
end
