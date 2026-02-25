defmodule Sentry.TelemetryProcessorIntegrationTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.TelemetryProcessor
  alias Sentry.Telemetry.Buffer
  alias Sentry.{LogEvent, Transaction}

  setup context do
    bypass = Bypass.open()
    test_pid = self()
    ref = make_ref()

    Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {ref, body})
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    stop_supervised!(context.telemetry_processor)

    uid = System.unique_integer([:positive])
    processor_name = :"test_integration_#{uid}"

    start_supervised!(
      {TelemetryProcessor, name: processor_name, buffer_configs: %{log: %{batch_size: 1}}},
      id: processor_name
    )

    Process.put(:sentry_telemetry_processor, processor_name)
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")

    %{processor: processor_name, ref: ref, bypass: bypass}
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

      bodies = collect_envelope_bodies(ctx.ref, 1)
      assert length(bodies) == 1

      [items] = Enum.map(bodies, &decode_envelope!/1)
      assert [{%{"type" => "event"}, event}] = items
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

      bodies = collect_envelope_bodies(ctx.ref, 5)
      items = Enum.map(bodies, &decode_envelope!/1)
      categories = Enum.map(items, &decoded_envelope_category/1)

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

      bodies = collect_envelope_bodies(ctx.ref, 5)
      items = Enum.map(bodies, &decode_envelope!/1)
      assert length(items) == 5
      assert Enum.all?(items, fn [{%{"type" => type}, _}] -> type == "event" end)
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

      bodies = collect_envelope_bodies(ctx.ref, 1)
      assert length(bodies) == 1

      [items] = Enum.map(bodies, &decode_envelope!/1)
      assert [{%{"type" => "check_in"}, check_in}] = items
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

      bodies = collect_envelope_bodies(ctx.ref, 3)
      items = Enum.map(bodies, &decode_envelope!/1)
      assert length(items) == 3
      assert Enum.all?(items, fn [{%{"type" => type}, _}] -> type == "check_in" end)
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

      bodies = collect_envelope_bodies(ctx.ref, 1)
      assert length(bodies) == 1

      [items] = Enum.map(bodies, &decode_envelope!/1)
      assert [{%{"type" => "transaction"}, transaction_data}] = items
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

      bodies = collect_envelope_bodies(ctx.ref, 3)
      items = Enum.map(bodies, &decode_envelope!/1)
      assert length(items) == 3
      assert Enum.all?(items, fn [{%{"type" => type}, _}] -> type == "transaction" end)
    end
  end

  describe "log batching" do
    test "sends log events as batched envelopes", ctx do
      TelemetryProcessor.add(ctx.processor, make_log_event("log-1"))
      TelemetryProcessor.add(ctx.processor, make_log_event("log-2"))

      bodies = collect_envelope_bodies(ctx.ref, 2)
      items = Enum.map(bodies, &decode_envelope!/1)
      assert length(items) == 2

      for [{header, payload}] <- items do
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

      bodies = collect_envelope_bodies(ctx.ref, 3)
      assert length(bodies) == 3
    end

    test "applies before_send_log callback", ctx do
      put_test_config(
        before_send_log: fn log_event ->
          if log_event.body == "drop me", do: nil, else: log_event
        end
      )

      TelemetryProcessor.add(ctx.processor, make_log_event("keep me"))
      TelemetryProcessor.add(ctx.processor, make_log_event("drop me"))

      bodies = collect_envelope_bodies(ctx.ref, 1)
      assert length(bodies) == 1

      [items] = Enum.map(bodies, &decode_envelope!/1)
      assert [{%{"type" => "log"}, %{"items" => [%{"body" => "keep me"}]}}] = items

      # The dropped event should not produce an envelope
      ref = ctx.ref
      refute_receive {^ref, _body}, 200
    end
  end

  describe "buffer overflow client reports" do
    setup ctx do
      stop_supervised!(ctx.processor)

      uid = System.unique_integer([:positive])
      processor_name = :"test_overflow_#{uid}"

      start_supervised!(
        {TelemetryProcessor,
         name: processor_name, buffer_configs: %{log: %{capacity: 2, batch_size: 1}}},
        id: processor_name
      )

      Process.put(:sentry_telemetry_processor, processor_name)

      Sentry.ClientReport.Sender.flush()
      flush_ref_messages(ctx.ref)

      %{processor: processor_name}
    end

    test "sends cache_overflow client report when log buffer overflows", ctx do
      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)
      :sys.suspend(scheduler)

      TelemetryProcessor.add(ctx.processor, make_log_event("log-1"))
      TelemetryProcessor.add(ctx.processor, make_log_event("log-2"))
      TelemetryProcessor.add(ctx.processor, make_log_event("log-3"))

      log_buffer = TelemetryProcessor.get_buffer(ctx.processor, :log)
      _ = Buffer.size(log_buffer)

      Sentry.ClientReport.Sender.flush()

      ref = ctx.ref
      assert_receive {^ref, body}, 2000

      items = decode_envelope!(body)
      assert [{%{"type" => "client_report"}, client_report}] = items

      cache_overflow =
        Enum.find(client_report["discarded_events"], &(&1["reason"] == "cache_overflow"))

      assert cache_overflow["category"] == "log_item"
      assert cache_overflow["quantity"] == 1

      :sys.resume(scheduler)
    end
  end

  describe "scheduler rate limiting" do
    setup ctx do
      put_test_config(telemetry_processor_categories: [:error, :check_in, :transaction, :log])

      Bypass.stub(ctx.bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      Sentry.ClientReport.Sender.flush()

      on_exit(fn ->
        for category <- ~w(log_item error monitor transaction) do
          try do
            :ets.delete(Sentry.Transport.RateLimiter, category)
          catch
            :error, :badarg -> :ok
          end
        end
      end)

      :ok
    end

    test "rate-limited HTTP response causes subsequent events to be dropped with client report",
         ctx do
      test_pid = self()
      ref = make_ref()
      request_count = :counters.new(1, [])

      # Use HackneyClient because FinchClient (Mint) lowercases response headers,
      # which prevents the transport from matching "X-Sentry-Rate-Limits".
      put_test_config(client: Sentry.HackneyClient)

      Bypass.expect(ctx.bypass, "POST", "/api/1/envelope/", fn conn ->
        count = :counters.get(request_count, 1)
        :counters.add(request_count, 1, 1)
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {ref, body})

        if count == 0 do
          conn
          |> Plug.Conn.put_resp_header("X-Sentry-Rate-Limits", "60:error:organization")
          |> Plug.Conn.resp(200, ~s<{"id": "340"}>)
        else
          Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
        end
      end)

      Sentry.capture_message("first-error", result: :none)

      assert_receive {^ref, body}, 2000
      assert [{%{"type" => "event"}, event}] = decode_envelope!(body)
      assert event["message"]["formatted"] == "first-error"

      scheduler = TelemetryProcessor.get_scheduler(ctx.processor)

      poll_until(fn ->
        %{active_ref: active_ref} = :sys.get_state(scheduler)
        is_nil(active_ref)
      end)

      Sentry.capture_message("rate-limited-error", result: :none)

      refute_receive {^ref, _body}, 200

      Sentry.ClientReport.Sender.flush()

      assert_receive {^ref, body}, 2000
      items = decode_envelope!(body)
      assert [{%{"type" => "client_report"}, client_report}] = items

      ratelimit_event =
        Enum.find(client_report["discarded_events"], &(&1["reason"] == "ratelimit_backoff"))

      assert ratelimit_event != nil
      assert ratelimit_event["category"] == "error"
      assert ratelimit_event["quantity"] == 1
    end
  end

  describe "pre-buffer rate limit checks" do
    setup ctx do
      Sentry.ClientReport.Sender.flush()
      flush_ref_messages(ctx.ref)

      rate_limiter_table = Process.get(:rate_limiter_table_name)

      on_exit(fn ->
        try do
          :ets.delete(rate_limiter_table, "log_item")
          :ets.delete(rate_limiter_table, "error")
          :ets.delete(rate_limiter_table, "monitor")
          :ets.delete(rate_limiter_table, "transaction")
        catch
          :error, :badarg -> :ok
        end
      end)

      %{rate_limiter_table: rate_limiter_table}
    end

    test "drops rate-limited log events before they enter the buffer", ctx do
      Bypass.stub(ctx.bypass, "POST", "/api/1/envelope/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      log_buffer = TelemetryProcessor.get_buffer(ctx.processor, :log)

      :ets.insert(ctx.rate_limiter_table, {"log_item", System.system_time(:second) + 60})

      assert {:ok, {:rate_limited, "log_item"}} =
               TelemetryProcessor.add(ctx.processor, make_log_event("pre-buffer-drop"))

      assert Buffer.size(log_buffer) == 0
    end

    test "drops rate-limited error events before they enter the buffer", ctx do
      put_test_config(telemetry_processor_categories: [:error, :log])

      error_buffer = TelemetryProcessor.get_buffer(ctx.processor, :error)

      :ets.insert(ctx.rate_limiter_table, {"error", System.system_time(:second) + 60})

      Sentry.capture_message("pre-buffer-drop", result: :none)

      assert Buffer.size(error_buffer) == 0

      Sentry.ClientReport.Sender.flush()

      ref = ctx.ref
      assert_receive {^ref, body}, 2000

      items = decode_envelope!(body)
      assert [{%{"type" => "client_report"}, client_report}] = items

      ratelimit_event =
        Enum.find(client_report["discarded_events"], &(&1["reason"] == "ratelimit_backoff"))

      assert ratelimit_event != nil
      assert ratelimit_event["category"] == "error"
      assert ratelimit_event["quantity"] == 1
    end

    test "drops rate-limited check-in events before they enter the buffer", ctx do
      put_test_config(telemetry_processor_categories: [:check_in, :log])

      check_in_buffer = TelemetryProcessor.get_buffer(ctx.processor, :check_in)

      :ets.insert(ctx.rate_limiter_table, {"monitor", System.system_time(:second) + 60})

      {:ok, _id} = Sentry.capture_check_in(status: :ok, monitor_slug: "dropped-job")

      assert Buffer.size(check_in_buffer) == 0

      Sentry.ClientReport.Sender.flush()

      ref = ctx.ref
      assert_receive {^ref, body}, 2000

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

      :ets.insert(ctx.rate_limiter_table, {"transaction", System.system_time(:second) + 60})

      assert {:ok, {:rate_limited, "transaction"}} =
               TelemetryProcessor.add(ctx.processor, make_transaction())

      assert Buffer.size(transaction_buffer) == 0
    end
  end

  defp make_transaction do
    now = System.system_time(:microsecond)

    %Transaction{
      event_id: Sentry.UUID.uuid4_hex(),
      span_id: Sentry.UUID.uuid4_hex() |> binary_part(0, 16),
      start_timestamp: (now - 1_000_000) / 1_000_000,
      timestamp: now / 1_000_000,
      spans: []
    }
  end

  defp flush_ref_messages(ref) do
    receive do
      {^ref, _body} -> flush_ref_messages(ref)
    after
      100 -> :ok
    end
  end

  defp make_log_event(body) do
    %LogEvent{
      timestamp: System.system_time(:nanosecond) / 1_000_000_000,
      level: :info,
      body: body
    }
  end

  defp collect_envelope_bodies(ref, expected_count) do
    collect_envelope_bodies(ref, expected_count, [])
  end

  defp collect_envelope_bodies(_ref, 0, acc), do: Enum.reverse(acc)

  defp collect_envelope_bodies(ref, remaining, acc) do
    receive do
      {^ref, body} -> collect_envelope_bodies(ref, remaining - 1, [body | acc])
    after
      2000 -> Enum.reverse(acc)
    end
  end

  defp decoded_envelope_category([{%{"type" => "event"}, _} | _]), do: :error
  defp decoded_envelope_category([{%{"type" => "check_in"}, _} | _]), do: :check_in
  defp decoded_envelope_category([{%{"type" => "transaction"}, _} | _]), do: :transaction
  defp decoded_envelope_category([{%{"type" => "log"}, _} | _]), do: :log

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
