defmodule Sentry.ApplicationTest do
  use ExUnit.Case, async: false

  require Logger

  describe "auto logger handler when enable_logs is true" do
    setup do
      on_exit(fn ->
        _ = :logger.remove_handler(:sentry_log_handler)
      end)
    end

    test "attaches :sentry_log_handler with defaults" do
      restart_sentry_with(enable_logs: true)

      assert {:ok, config} = :logger.get_handler_config(:sentry_log_handler)
      assert config.module == Sentry.LoggerHandler
      assert Sentry.Config.logs_level() == :info
      assert Sentry.Config.logs_excluded_domains() == []
      assert Sentry.Config.logs_metadata() == []
    end

    test "respects logs.level config" do
      restart_sentry_with(enable_logs: true, logs: [level: :warning])

      assert {:ok, _config} = :logger.get_handler_config(:sentry_log_handler)
      assert Sentry.Config.logs_level() == :warning
    end

    test "respects logs.excluded_domains config" do
      restart_sentry_with(enable_logs: true, logs: [excluded_domains: [:cowboy, :ranch]])

      assert {:ok, _config} = :logger.get_handler_config(:sentry_log_handler)
      assert Sentry.Config.logs_excluded_domains() == [:cowboy, :ranch]
    end

    test "respects logs.metadata config" do
      restart_sentry_with(enable_logs: true, logs: [metadata: [:request_id, :user_id]])

      assert {:ok, _config} = :logger.get_handler_config(:sentry_log_handler)
      assert Sentry.Config.logs_metadata() == [:request_id, :user_id]
    end

    test "does not attach handler when enable_logs is false" do
      restart_sentry_with(enable_logs: false)

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

      restart_sentry_with(enable_logs: true)

      assert {:error, {:not_found, :sentry_log_handler}} =
               :logger.get_handler_config(:sentry_log_handler)

      assert {:ok, _} = :logger.get_handler_config(existing_handler)
    end

    test "auto-handler captures logs to the buffer" do
      restart_sentry_with(enable_logs: true)

      assert {:ok, _} = :logger.get_handler_config(:sentry_log_handler)

      initial_size = Sentry.TelemetryProcessor.buffer_size(:log)

      Logger.info("Auto-handler integration test message")

      wait_until(fn ->
        Sentry.TelemetryProcessor.buffer_size(:log) > initial_size
      end)

      assert Sentry.TelemetryProcessor.buffer_size(:log) > initial_size
    end
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

  defp wait_until(condition_fn, timeout \\ 1000) do
    end_time = System.monotonic_time(:millisecond) + timeout
    wait_loop(condition_fn, end_time, 1)
  end

  defp wait_loop(condition_fn, end_time, sleep_time) do
    cond do
      condition_fn.() ->
        :ok

      System.monotonic_time(:millisecond) >= end_time ->
        :timeout

      true ->
        Process.sleep(sleep_time)
        wait_loop(condition_fn, end_time, min(sleep_time * 2, 50))
    end
  end
end
