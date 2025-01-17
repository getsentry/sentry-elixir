defmodule Sentry.DedupeTest do
  # This is not async because it tests a singleton (the dedupe GenServer).
  use Sentry.Case, async: false

  alias Sentry.Dedupe
  alias Sentry.Event

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
      Process.sleep(5)
      send(Dedupe, {:sweep, 0})
      _ = :sys.get_state(Dedupe)

      # Now, it's :new again.
      assert Dedupe.insert(event) == :new
      assert Dedupe.insert(event) == :existing
    end

    for key <- Map.keys(Sentry.Context.get_all()) do
      test "takes .#{key} context into account" do
        event = fn ctx ->
          %Event{
            :message => "Something went wrong",
            :timestamp => System.system_time(:millisecond),
            :event_id => Sentry.UUID.uuid4_hex(),
            unquote(key) => ctx
          }
        end

        assert Dedupe.insert(event.(%{"ctx" => "1"})) == :new
        assert Dedupe.insert(event.(%{"ctx" => "1"})) == :existing

        assert Dedupe.insert(event.(%{"ctx" => "2"})) == :new
        assert Dedupe.insert(event.(%{"ctx" => "2"})) == :existing

        assert Dedupe.insert(event.(%{"ctx" => "1"})) == :existing
        assert Dedupe.insert(event.(%{"ctx" => "2"})) == :existing
      end
    end
  end
end
