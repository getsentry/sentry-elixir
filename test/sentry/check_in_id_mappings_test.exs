defmodule Sentry.CheckInIDMappingsTest do
  # This is not async because it tests a singleton (the CheckInIDMappings GenServer).
  use Sentry.Case, async: false

  alias Sentry.Integrations.CheckInIDMappings
  @table :sentry_cron_mappings

  describe "lookup_or_insert_new/1" do
    test "works correctly" do
      cron_key = "quantum_123"

      child_spec = %{
        id: TestMappings,
        start:
          {CheckInIDMappings, :start_link, [[max_expected_check_in_time: 0, name: TestMappings]]}
      }

      pid = start_supervised!(child_spec)

      CheckInIDMappings.lookup_or_insert_new(cron_key)
      assert :ets.lookup(@table, cron_key) != []

      Process.sleep(5)
      send(pid, :sweep)
      _ = :sys.get_state(pid)

      assert :ets.lookup(@table, cron_key) == []
    end
  end
end
