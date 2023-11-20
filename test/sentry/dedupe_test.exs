defmodule Sentry.DedupeTest do
  # This is not async because it tests a singleton (the dedupe GenServer).
  use ExUnit.Case, async: false

  alias Sentry.Dedupe
  alias Sentry.Event

  @ttl_millisec 25

  describe "insert/1" do
    test "works correctly" do
      stop_application()
      start_supervised({Dedupe, ttl_millisec: @ttl_millisec})

      event = %Event{
        message: "Something went wrong",
        timestamp: System.system_time(:millisecond),
        event_id: Sentry.UUID.uuid4_hex()
      }

      # First time, it's :new.
      assert Dedupe.insert(event) == :new

      # Then, it's :existing.
      assert Dedupe.insert(event) == :existing
      assert Dedupe.insert(event) == :existing

      # Now, we trigger a sweep after waiting for the TTL interval.
      # To ensure the :sweep message is processed, we use the trick
      # of asking the GenServer for its state (which is a sync call).
      Process.sleep(@ttl_millisec * 2)
      send(Dedupe, :sweep)
      _ = :sys.get_state(Dedupe)

      # Now, it's :new again.
      assert Dedupe.insert(event) == :new
      assert Dedupe.insert(event) == :existing
    end
  end

  defp stop_application do
    for {{:sentry_config, _} = key, _val} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    ExUnit.CaptureLog.capture_log(fn -> Application.stop(:sentry) end)
  end
end
