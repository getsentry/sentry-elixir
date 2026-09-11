defmodule Sentry.ApplicationTest do
  use ExUnit.Case, async: false

  import Sentry.TestHelpers

  import Sentry.Test.Assertions,
    only: [assert_sentry_report: 2, find_sentry_report!: 2]

  require Logger

  describe "auto logger handler" do
    setup do
      on_exit(fn ->
        _ = :logger.remove_handler(:sentry_log_handler)
      end)
    end

    test "attaches :sentry_log_handler with defaults" do
      restart_sentry_with(dsn: "https://public@sentry.example.com/1", logs: [])

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.module == Sentry.LoggerHandler
      assert handler.config.capture_log_messages == false
      assert handler.config.capture_level == :error
      assert handler.config.capture_metadata == []
      assert handler.config.capture_excluded_domains == [:cowboy]

      assert handler.config.logs_level == nil
      assert handler.config.logs_excluded_domains == []
      assert handler.config.logs_metadata == []
    end

    test "respects logs.capture_log_messages and logs.capture_level config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        logs: [capture_log_messages: true, capture_level: :warning]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.config.capture_log_messages == true
      assert handler.config.capture_level == :warning
    end

    test "respects logs.level config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        logs: [level: :warning]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.config.logs_level == :warning
    end

    test "respects logs.excluded_domains config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        logs: [excluded_domains: [:cowboy, :ranch]]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      # :excluded_domains is for the logs feature; captured Sentry event exclusions are
      # governed by the separate :capture_excluded_domains option.
      assert handler.config.capture_excluded_domains == [:cowboy]
      assert handler.config.logs_excluded_domains == [:cowboy, :ranch]
    end

    test "respects logs.capture_excluded_domains config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        logs: [capture_excluded_domains: [:cowboy, :ranch]]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.config.capture_excluded_domains == [:cowboy, :ranch]
    end

    test "respects logs.metadata config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        logs: [metadata: [:request_id, :user_id]]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      # :metadata is for the logs feature; it must not leak into captured event metadata,
      # which is governed by the separate :capture_metadata option.
      assert handler.config.capture_metadata == []
      assert handler.config.logs_metadata == [:request_id, :user_id]
    end

    test "respects logs.capture_metadata config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        logs: [capture_metadata: [:request_id, :user_id]]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.config.capture_metadata == [:request_id, :user_id]
    end

    test "re-syncs the handler's capture config when restarted while already registered" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        logs: [
          level: :info,
          excluded_domains: [:cowboy],
          metadata: [:trace_id],
          capture_metadata: [:request_id],
          capture_excluded_domains: [:cowboy]
        ]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.config.logs_level == :info
      assert handler.config.logs_excluded_domains == [:cowboy]
      assert handler.config.logs_metadata == [:trace_id]
      assert handler.config.capture_metadata == [:request_id]
      assert handler.config.capture_excluded_domains == [:cowboy]

      # Restart again WITHOUT removing the handler first. The handler survives the stop, so
      # the start path must re-sync the handler's frozen options to the new config.
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        logs: [
          level: :warning,
          excluded_domains: [:ranch],
          metadata: :all,
          capture_metadata: [:request_id, :user_id],
          capture_excluded_domains: [:ranch]
        ]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.config.logs_level == :warning
      assert handler.config.logs_excluded_domains == [:ranch]
      assert handler.config.logs_metadata == :all
      assert handler.config.capture_metadata == [:request_id, :user_id]
      assert handler.config.capture_excluded_domains == [:ranch]
    end

    test "does not attach the handler when :logs is not configured" do
      restart_sentry_with(dsn: "https://public@sentry.example.com/1")

      assert {:error, {:not_found, :sentry_log_handler}} =
               :logger.get_handler_config(:sentry_log_handler)
    end

    test "removes the auto-handler when :logs becomes nil" do
      restart_sentry_with(dsn: "https://public@sentry.example.com/1", logs: [])
      assert {:ok, _} = :logger.get_handler_config(:sentry_log_handler)

      restart_sentry_with(dsn: "https://public@sentry.example.com/1", logs: nil)

      assert {:error, {:not_found, :sentry_log_handler}} =
               :logger.get_handler_config(:sentry_log_handler)
    end

    test "skips auto-handler when a Sentry.LoggerHandler is already registered" do
      existing_handler = :"existing_sentry_handler_#{System.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(existing_handler, Sentry.LoggerHandler, %{
          config: %{}
        })

      on_exit(fn ->
        _ = :logger.remove_handler(existing_handler)
      end)

      restart_sentry_with(dsn: "https://public@sentry.example.com/1", logs: [])

      assert {:error, {:not_found, :sentry_log_handler}} =
               :logger.get_handler_config(:sentry_log_handler)

      assert {:ok, _} = :logger.get_handler_config(existing_handler)
    end

    test "removes auto-handler when a user adds their own Sentry.LoggerHandler after startup" do
      restart_sentry_with(dsn: "https://public@sentry.example.com/1", logs: [])
      assert {:ok, _} = :logger.get_handler_config(:sentry_log_handler)

      user_handler = :"user_sentry_handler_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        _ = :logger.remove_handler(user_handler)
      end)

      :ok = :logger.add_handler(user_handler, Sentry.LoggerHandler, %{config: %{}})

      assert {:ok, _} = :logger.get_handler_config(user_handler)

      wait_until(fn ->
        match?(
          {:error, {:not_found, :sentry_log_handler}},
          :logger.get_handler_config(:sentry_log_handler)
        )
      end)

      assert {:error, {:not_found, :sentry_log_handler}} =
               :logger.get_handler_config(:sentry_log_handler)
    end

    test "keeps auto-handler when a user adds a Sentry.LoggerHandler with invalid config" do
      restart_sentry_with(dsn: "https://public@sentry.example.com/1", logs: [])
      assert {:ok, _} = :logger.get_handler_config(:sentry_log_handler)

      user_handler = :"user_sentry_handler_#{System.unique_integer([:positive])}"

      assert {:error, _reason} =
               :logger.add_handler(user_handler, Sentry.LoggerHandler, %{
                 config: %{sync_threshold: 10, discard_threshold: 20}
               })

      assert {:ok, _} = :logger.get_handler_config(:sentry_log_handler)
      assert {:error, {:not_found, ^user_handler}} = :logger.get_handler_config(user_handler)
    end

    test "auto-handler sends logs to Sentry" do
      bypass = Bypass.open()
      ref = setup_bypass_envelope_collector(bypass, type: "log")

      restart_sentry_with(
        dsn: "http://public:secret@localhost:#{bypass.port}/1",
        test_mode: false,
        traces_sample_rate: 0.0,
        logs: [level: :warning],
        finch_request_opts: [receive_timeout: 2_000]
      )

      Logger.warning("Auto-handler integration test message")
      assert :ok = Application.stop(:sentry)

      assert [%{"items" => logs}] = collect_sentry_logs(ref, 1)
      find_sentry_report!(logs, level: "warn", body: "Auto-handler integration test message")
    end
  end

  describe "graceful shutdown" do
    setup context do
      bypass = Bypass.open()

      restart_sentry_with(
        dsn: "http://public:secret@localhost:#{bypass.port}/1",
        test_mode: false,
        traces_sample_rate: 0.0,
        logs: if(context[:capture_logs], do: [level: :warning]),
        telemetry_processor_categories: [:error, :log],
        finch_request_opts: [receive_timeout: 2_000]
      )

      collector_opts =
        if context[:capture_logs], do: [type: ["log", "trace_metric"]], else: []

      %{bypass: bypass, ref: setup_bypass_envelope_collector(bypass, collector_opts)}
    end

    @tag capture_logs: true
    test "delivers pending logs and metrics on application stop", %{ref: ref} do
      Logger.warning("pending at shutdown")
      Sentry.Metrics.gauge("shutdown.metric", 42)
      assert collect_envelopes(ref, 1, timeout: 0) == []

      assert :ok = Application.stop(:sentry)

      envelopes = collect_envelopes(ref, 2)
      assert [%{"items" => logs}] = extract_log_items(envelopes)
      assert [%{"items" => metrics}] = extract_metric_items(envelopes)
      find_sentry_report!(logs, level: "warn", body: "pending at shutdown")
      assert_sentry_report(metrics, type: "gauge", name: "shutdown.metric", value: 42)
    end

    test "waits for pending requests before completing shutdown", %{bypass: bypass} do
      owner = self()

      setup_bypass_envelope_collector(bypass,
        response: fn conn, body ->
          if body =~ "active at shutdown" or body =~ "queued at shutdown" do
            hold_response(conn, owner, body)
          else
            successful_response(conn)
          end
        end
      )

      Sentry.capture_message("active at shutdown", result: :none)
      assert_receive {:request_started, first_handler, first_body}

      Sentry.capture_message("queued at shutdown", result: :none)
      task = Task.async(fn -> Application.stop(:sentry) end)

      try do
        assert Task.yield(task, 50) == nil
        send(first_handler, :release)

        assert_receive {:request_started, second_handler, second_body}

        try do
          assert Task.yield(task, 50) == nil
        after
          send(second_handler, :release)
        end

        assert :ok = Task.await(task)
        assert [first] = extract_events([decode_envelope!(first_body)])
        assert [second] = extract_events([decode_envelope!(second_body)])
        assert_sentry_report(first, message: %{formatted: "active at shutdown"})
        assert_sentry_report(second, message: %{formatted: "queued at shutdown"})
      after
        send(first_handler, :release)
      end
    end

    test "allows shutdown to finish after five seconds without an HTTP response", %{
      bypass: bypass
    } do
      owner = self()
      Sentry.put_config(:finch_request_opts, receive_timeout: 10_000)

      setup_bypass_envelope_collector(bypass,
        response: fn conn, body ->
          if body =~ ~s("type":"trace_metric") do
            # Shutdown is expected to close this connection before a response arrives.
            Bypass.pass(bypass)
            hold_response(conn, owner)
          else
            successful_response(conn)
          end
        end
      )

      Sentry.Metrics.gauge("shutdown.metric", 42)
      started_at = System.monotonic_time(:millisecond)
      task = Task.async(fn -> Application.stop(:sentry) end)
      assert_receive {:request_started, handler}

      try do
        assert :ok = Task.await(task, 7_000)
        assert System.monotonic_time(:millisecond) - started_at >= 5_000
      after
        send(handler, :release)
      end
    end

    test "still stops when Sentry responds with an HTTP error", %{bypass: bypass} do
      ref =
        setup_bypass_envelope_collector(bypass,
          type: "trace_metric",
          response: fn conn, body ->
            if body =~ ~s("type":"trace_metric") do
              Plug.Conn.resp(conn, 500, "unavailable")
            else
              successful_response(conn)
            end
          end
        )

      Sentry.Metrics.gauge("shutdown.metric", 42)
      assert :ok = Application.stop(:sentry)

      assert [%{"items" => metrics}] = collect_sentry_metric_items(ref, 1)
      assert_sentry_report(metrics, name: "shutdown.metric", value: 42)
    end
  end

  defp hold_response(conn, owner) do
    send(owner, {:request_started, self()})

    receive do
      :release -> Plug.Conn.resp(conn, 200, "{}")
    after
      10_000 -> Plug.Conn.resp(conn, 500, "response was not released")
    end
  end

  defp hold_response(conn, owner, body) do
    send(owner, {:request_started, self(), body})

    receive do
      :release -> successful_response(conn)
    after
      10_000 -> Plug.Conn.resp(conn, 500, "response was not released")
    end
  end

  defp successful_response(conn) do
    Plug.Conn.resp(conn, 200, ~s({"id":"#{Sentry.UUID.uuid4_hex()}"}))
  end

  defp restart_sentry_with(config) do
    Application.stop(:sentry)

    originals =
      for {key, val} <- config do
        original = Application.get_env(:sentry, key)
        Application.put_env(:sentry, key, val)
        {key, original}
      end

    ExUnit.Callbacks.on_exit(fn ->
      Application.stop(:sentry)

      for {key, original} <- originals do
        if original do
          Application.put_env(:sentry, key, original)
        else
          Application.delete_env(:sentry, key)
        end
      end

      Application.ensure_all_started(:sentry)
    end)

    {:ok, _} = Application.ensure_all_started(:sentry)
  end
end
