defmodule ProdModeTest do
  use ExUnit.Case, async: false

  alias ProdMode.Callback

  setup do
    Callback.reset()
    :ok
  end

  describe "running with test_mode: false and dsn: nil" do
    test "Mix env is :prod and test_mode is disabled" do
      assert Mix.env() == :prod
      refute Sentry.Config.test_mode?()
      assert is_nil(Sentry.Config.dsn())
    end

    test "capture_exception/2 is a no-op and never invokes the user before_send" do
      assert :ignored = Sentry.capture_exception(%RuntimeError{message: "boom"}, result: :sync)
      assert [] == Callback.calls()
    end

    test "capture_message/2 is a no-op and never invokes the user before_send" do
      assert :ignored = Sentry.capture_message("hello", result: :sync)
      assert [] == Callback.calls()
    end

    test "send_transaction/2 is a no-op and never invokes the user before_send" do
      transaction =
        Sentry.Transaction.new(%{
          span_id: "prod-mode-span",
          start_timestamp: "2025-01-01T00:00:00Z",
          timestamp: "2025-01-02T00:00:00Z",
          contexts: %{trace: %{trace_id: "prod-mode-trace", span_id: "prod-mode-span"}},
          spans: []
        })

      assert :ignored = Sentry.send_transaction(transaction, result: :sync)
      assert [] == Callback.calls()
    end

    test "capture_check_in/1 is a no-op without raising" do
      assert :ignored = Sentry.capture_check_in(status: :ok, monitor_slug: "prod-mode-job")
      assert [] == Callback.calls()
    end

    test "Sentry.Config.before_send/0 returns nil" do
      # The composed callback should resolve to nil when neither a DSN is set
      # nor test_mode is enabled, even though the user has configured a
      # before_send callback.
      assert is_nil(Sentry.Config.before_send())
    end
  end
end
