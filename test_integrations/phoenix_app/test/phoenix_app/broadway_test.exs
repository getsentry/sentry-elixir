defmodule PhoenixApp.BroadwayTest do
  # async: true — the auto-allowance design routes per-message via the
  # :sentry_test_owner metadata, which Broadway propagates onto the
  # %Broadway.Message{} struct. Two of these tests racing against each
  # other on the same shared pipeline still produce the right per-test
  # results because each message carries its origin test pid.
  use ExUnit.Case, async: true

  describe "setup_sentry/1 with allowance: [Broadway]" do
    setup do
      Sentry.Test.setup_sentry(allowance: [Broadway])
      start_supervised!(PhoenixApp.TestBroadway)
      :ok
    end

    test "events from a Broadway processor are captured when tagged via metadata" do
      ref =
        Broadway.test_message(PhoenixApp.TestBroadway, :capture,
          metadata: %{sentry_test_owner: self()}
        )

      assert_receive {:ack, ^ref, [_succeeded], []}, 5_000

      assert [%Sentry.Event{message: %{formatted: "from broadway"}}] =
               Sentry.Test.pop_sentry_reports()
    end

    test "raw Broadway.test_message without :sentry_test_owner is not auto-allowed" do
      ref = Broadway.test_message(PhoenixApp.TestBroadway, :capture)

      assert_receive {:ack, ^ref, [_succeeded], []}, 5_000
      assert [] == Sentry.Test.pop_sentry_reports()
    end
  end

  describe "without allowance" do
    setup do
      Sentry.Test.setup_sentry()
      start_supervised!(PhoenixApp.TestBroadway)
      :ok
    end

    test "tagged messages are still dropped without allowance: [Broadway]" do
      ref =
        Broadway.test_message(PhoenixApp.TestBroadway, :capture,
          metadata: %{sentry_test_owner: self()}
        )

      assert_receive {:ack, ^ref, [_succeeded], []}, 5_000
      assert [] == Sentry.Test.pop_sentry_reports()
    end
  end
end
