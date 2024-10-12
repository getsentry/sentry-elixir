defmodule Sentry.ClientReportTest do
  use Sentry.Case, async: true

  alias Sentry.ClientReport

  describe "add_discarded_event/1" do
    test "records discarded event to state" do
      assert :sys.get_state(ClientReport) == %{}

      ClientReport.add_discarded_event(:event_processor, "error")

      assert :sys.get_state(ClientReport) == %{{:event_processor, "error"} => 1}

      ClientReport.add_discarded_event(:event_processor, "error")
      ClientReport.add_discarded_event(:event_processor, "error")
      ClientReport.add_discarded_event(:network_error, "error")

      # updates quantity when duplcate events are sent
      assert :sys.get_state(ClientReport) == %{
               {:event_processor, "error"} => 3,
               {:network_error, "error"} => 1
             }
    end
  end
end
