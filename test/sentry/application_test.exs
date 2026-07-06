defmodule Sentry.ApplicationTest do
  use ExUnit.Case, async: false

  import Sentry.TestHelpers, only: [wait_until: 1]

  require Logger

  describe "auto logger handler when enable_logs is true" do
    setup do
      on_exit(fn ->
        _ = :logger.remove_handler(:sentry_log_handler)
      end)
    end

    test "attaches :sentry_log_handler with defaults" do
      restart_sentry_with(dsn: "https://public@sentry.example.com/1", enable_logs: true)

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.module == Sentry.LoggerHandler
      assert Sentry.Config.logs_level() == :info
      assert Sentry.Config.logs_excluded_domains() == []
      assert Sentry.Config.logs_metadata() == []

      assert handler.config.capture_log_messages == false
      assert handler.config.capture_level == :error
      assert handler.config.capture_metadata == []
      assert handler.config.capture_excluded_domains == [:cowboy, :bandit]

      assert handler.config.logs_level == :info
      assert handler.config.logs_excluded_domains == []
      assert handler.config.logs_metadata == []
    end

    test "respects logs.capture_log_messages and logs.capture_level config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        enable_logs: true,
        logs: [capture_log_messages: true, capture_level: :warning]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.config.capture_log_messages == true
      assert handler.config.capture_level == :warning
    end

    test "respects logs.level config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        enable_logs: true,
        logs: [level: :warning]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert Sentry.Config.logs_level() == :warning
      assert handler.config.logs_level == :warning
    end

    test "respects logs.excluded_domains config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        enable_logs: true,
        logs: [excluded_domains: [:cowboy, :ranch]]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert Sentry.Config.logs_excluded_domains() == [:cowboy, :ranch]
      # :excluded_domains is for the logs feature; captured Sentry event exclusions are
      # governed by the separate :capture_excluded_domains option.
      assert handler.config.capture_excluded_domains == [:cowboy, :bandit]
      assert handler.config.logs_excluded_domains == [:cowboy, :ranch]
    end

    test "respects logs.capture_excluded_domains config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        enable_logs: true,
        logs: [capture_excluded_domains: [:cowboy, :ranch]]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.config.capture_excluded_domains == [:cowboy, :ranch]
    end

    test "respects logs.metadata config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        enable_logs: true,
        logs: [metadata: [:request_id, :user_id]]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert Sentry.Config.logs_metadata() == [:request_id, :user_id]
      # :metadata is for the logs feature; it must not leak into captured event metadata,
      # which is governed by the separate :capture_metadata option.
      assert handler.config.capture_metadata == []
      assert handler.config.logs_metadata == [:request_id, :user_id]
    end

    test "respects logs.capture_metadata config" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        enable_logs: true,
        logs: [capture_metadata: [:request_id, :user_id]]
      )

      assert {:ok, handler} = :logger.get_handler_config(:sentry_log_handler)
      assert handler.config.capture_metadata == [:request_id, :user_id]
    end

    test "re-syncs the handler's capture config when restarted while already registered" do
      restart_sentry_with(
        dsn: "https://public@sentry.example.com/1",
        enable_logs: true,
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
        enable_logs: true,
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

    test "does not attach handler when enable_logs is false" do
      restart_sentry_with(enable_logs: false)

      assert {:error, {:not_found, :sentry_log_handler}} =
               :logger.get_handler_config(:sentry_log_handler)
    end

    test "removes auto-handler when enable_logs becomes false" do
      restart_sentry_with(dsn: "https://public@sentry.example.com/1", enable_logs: true)
      assert {:ok, _} = :logger.get_handler_config(:sentry_log_handler)

      restart_sentry_with(dsn: "https://public@sentry.example.com/1", enable_logs: false)

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

      restart_sentry_with(dsn: "https://public@sentry.example.com/1", enable_logs: true)

      assert {:error, {:not_found, :sentry_log_handler}} =
               :logger.get_handler_config(:sentry_log_handler)

      assert {:ok, _} = :logger.get_handler_config(existing_handler)
    end

    test "removes auto-handler when a user adds their own Sentry.LoggerHandler after startup" do
      restart_sentry_with(dsn: "https://public@sentry.example.com/1", enable_logs: true)
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
      restart_sentry_with(dsn: "https://public@sentry.example.com/1", enable_logs: true)
      assert {:ok, _} = :logger.get_handler_config(:sentry_log_handler)

      user_handler = :"user_sentry_handler_#{System.unique_integer([:positive])}"

      assert {:error, _reason} =
               :logger.add_handler(user_handler, Sentry.LoggerHandler, %{
                 config: %{sync_threshold: 10, discard_threshold: 20}
               })

      assert {:ok, _} = :logger.get_handler_config(:sentry_log_handler)
      assert {:error, {:not_found, ^user_handler}} = :logger.get_handler_config(user_handler)
    end

    test "auto-handler captures logs to the buffer" do
      restart_sentry_with(dsn: "https://public@sentry.example.com/1", enable_logs: true)

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
end
