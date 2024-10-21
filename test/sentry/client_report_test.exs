defmodule Sentry.ClientReportTest do
  use Sentry.Case, async: false

  alias Sentry.{ClientReport, Event}

  describe "record_discarded_events/2" do
    test "succefully records the discarded event to the client report" do
      {:ok, _clientreport} = start_supervised({ClientReport, [name: :test_client_report]})

      events = [
        %Event{
          event_id: Sentry.UUID.uuid4_hex(),
          timestamp: "2024-10-12T13:21:13"
        }
      ]

      assert ClientReport.record_discarded_events(:before_send, events, :test_client_report) ==
               :ok

      assert :sys.get_state(:test_client_report) == %{{:before_send, "error"} => 1}

      ClientReport.record_discarded_events(:before_send, events, :test_client_report)

      assert :sys.get_state(:test_client_report) == %{{:before_send, "error"} => 2}

      ClientReport.record_discarded_events(:event_processor, events, :test_client_report)
      ClientReport.record_discarded_events(:network_error, events, :test_client_report)

      assert :sys.get_state(:test_client_report) == %{
               {:before_send, "error"} => 2,
               {:event_processor, "error"} => 1,
               {:network_error, "error"} => 1
             }
    end
  end
end
