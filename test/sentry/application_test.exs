defmodule Sentry.ApplicationTest do
  use ExUnit.Case, async: false

  require Logger

  describe "auto logger handler when enable_logs is true" do
    setup do
      on_exit(fn ->
        _ = :logger.remove_handler(:sentry_log_handler)
      end)
    end

    test "attaches :sentry_log_handler on application start" do
      # Stop the Sentry application so we can restart it with enable_logs: true
      Application.stop(:sentry)

      original_enable_logs = Application.get_env(:sentry, :enable_logs)
      Application.put_env(:sentry, :enable_logs, true)

      on_exit(fn ->
        Application.stop(:sentry)

        if original_enable_logs do
          Application.put_env(:sentry, :enable_logs, original_enable_logs)
        else
          Application.delete_env(:sentry, :enable_logs)
        end

        Application.ensure_all_started(:sentry)
      end)

      {:ok, _} = Application.ensure_all_started(:sentry)

      assert {:ok, config} = :logger.get_handler_config(:sentry_log_handler)
      assert config.module == Sentry.LoggerHandler
      assert config.config.logs_level == :info
    end

    test "does not attach handler when enable_logs is false" do
      Application.stop(:sentry)

      original_enable_logs = Application.get_env(:sentry, :enable_logs)
      Application.put_env(:sentry, :enable_logs, false)

      on_exit(fn ->
        Application.stop(:sentry)

        if original_enable_logs do
          Application.put_env(:sentry, :enable_logs, original_enable_logs)
        else
          Application.delete_env(:sentry, :enable_logs)
        end

        Application.ensure_all_started(:sentry)
      end)

      {:ok, _} = Application.ensure_all_started(:sentry)

      assert {:error, {:not_found, :sentry_log_handler}} =
               :logger.get_handler_config(:sentry_log_handler)
    end

    test "skips auto-handler when a Sentry.LoggerHandler is already registered" do
      existing_handler = :"existing_sentry_handler_#{System.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(existing_handler, Sentry.LoggerHandler, %{
          config: %{logs_level: :warning}
        })

      on_exit(fn ->
        _ = :logger.remove_handler(existing_handler)
      end)

      Application.stop(:sentry)

      original_enable_logs = Application.get_env(:sentry, :enable_logs)
      Application.put_env(:sentry, :enable_logs, true)

      on_exit(fn ->
        Application.stop(:sentry)

        if original_enable_logs do
          Application.put_env(:sentry, :enable_logs, original_enable_logs)
        else
          Application.delete_env(:sentry, :enable_logs)
        end

        Application.ensure_all_started(:sentry)
      end)

      {:ok, _} = Application.ensure_all_started(:sentry)

      assert {:error, {:not_found, :sentry_log_handler}} =
               :logger.get_handler_config(:sentry_log_handler)

      assert {:ok, _} = :logger.get_handler_config(existing_handler)
    end

    test "auto-handler captures logs to the buffer" do
      Application.stop(:sentry)

      original_enable_logs = Application.get_env(:sentry, :enable_logs)
      Application.put_env(:sentry, :enable_logs, true)

      on_exit(fn ->
        Application.stop(:sentry)

        if original_enable_logs do
          Application.put_env(:sentry, :enable_logs, original_enable_logs)
        else
          Application.delete_env(:sentry, :enable_logs)
        end

        Application.ensure_all_started(:sentry)
      end)

      {:ok, _} = Application.ensure_all_started(:sentry)

      assert {:ok, _} = :logger.get_handler_config(:sentry_log_handler)

      initial_size = Sentry.TelemetryProcessor.buffer_size(:log)

      Logger.info("Auto-handler integration test message")

      wait_until(fn ->
        Sentry.TelemetryProcessor.buffer_size(:log) > initial_size
      end)

      assert Sentry.TelemetryProcessor.buffer_size(:log) > initial_size
    end
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
