defmodule Sentry.ClientReportTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.ClientReport.Sender
  alias Sentry.Event

  setup do
    original_retries =
      Application.get_env(:sentry, :request_retries, Sentry.Transport.default_retries())

    on_exit(fn -> Application.put_env(:sentry, :request_retries, original_retries) end)

    Application.put_env(:sentry, :request_retries, [])

    bypass = Bypass.open()
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")
    %{bypass: bypass}
  end

  describe "record_discarded_events/2 + flushing" do
    test "succefully records the discarded event to the client report", %{bypass: bypass} do
      start_supervised!({Sender, name: :test_client_report})

      events = [
        %Event{
          event_id: Sentry.UUID.uuid4_hex(),
          timestamp: "2024-10-12T13:21:13"
        }
      ]

      assert :ok = Sender.record_discarded_events(:before_send, events, :test_client_report)

      assert :sys.get_state(:test_client_report) == %{{:before_send, "error"} => 1}

      assert :ok = Sender.record_discarded_events(:before_send, events, :test_client_report)

      assert :sys.get_state(:test_client_report) == %{{:before_send, "error"} => 2}

      assert :ok = Sender.record_discarded_events(:event_processor, events, :test_client_report)
      assert :ok = Sender.record_discarded_events(:network_error, events, :test_client_report)

      assert :sys.get_state(:test_client_report) == %{
               {:before_send, "error"} => 2,
               {:event_processor, "error"} => 1,
               {:network_error, "error"} => 1
             }

      send(Process.whereis(:test_client_report), :send_report)

      Bypass.expect(bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert [{%{"type" => "client_report", "length" => _}, client_report}] =
                 decode_envelope!(body)

        assert client_report["discarded_events"] == [
                 %{"reason" => "before_send", "category" => "error", "quantity" => 2},
                 %{"reason" => "event_processor", "category" => "error", "quantity" => 1},
                 %{"reason" => "network_error", "category" => "error", "quantity" => 1}
               ]

        assert client_report["timestamp"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      assert :sys.get_state(:test_client_report) == %{}
    end
  end
end
