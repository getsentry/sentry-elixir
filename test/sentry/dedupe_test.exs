defmodule Sentry.DedupeTest do
  # This is not async because it tests a singleton (the dedupe GenServer).
  use ExUnit.Case, async: false

  alias Sentry.Dedupe
  alias Sentry.Event

  @ttl_millisec 25

  describe "insert/1" do
    test "works correctly" do
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
      send(Dedupe, {:sweep, @ttl_millisec})
      _ = :sys.get_state(Dedupe)

      # Now, it's :new again.
      assert Dedupe.insert(event) == :new
      assert Dedupe.insert(event) == :existing
    end
  end
end
