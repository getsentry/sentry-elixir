defmodule Sentry.CheckInIDMappingsTest do
  # This is not async because it tests a singleton (the CheckInIDMappings GenServer).
  use Sentry.Case, async: false

  alias Sentry.Integrations.CheckInIDMappings

  describe "lookup_or_insert_new/1" do
    test "works correctly" do
      cron_key = "quantum_123"

      CheckInIDMappings.lookup_or_insert_new(cron_key)
      assert :ets.lookup(:sentry_cron_mappings, cron_key) != []

      Process.sleep(5)
      send(CheckInIDMappings, {:sweep, 0})
      _ = :sys.get_state(CheckInIDMappings)

      assert :ets.lookup(:sentry_cron_mappings, cron_key) == []
    end
  end
end
