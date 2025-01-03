defmodule Sentry.EnvelopeTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.{Attachment, CheckIn, ClientReport, Envelope, Event}

  describe "to_binary/1" do
    test "encodes an envelope" do
      put_test_config(environment_name: "test")
      event = Event.create_event([])

      envelope = Envelope.from_event(event)

      assert {:ok, encoded} = Envelope.to_binary(envelope)

      assert [id_line, header_line, event_line] = String.split(encoded, "\n", trim: true)
      assert decode!(id_line) == %{"event_id" => event.event_id}
      assert %{"type" => "event", "length" => _} = decode!(header_line)

      decoded_event = decode!(event_line)
      assert decoded_event["event_id"] == event.event_id
      assert decoded_event["breadcrumbs"] == []
      assert decoded_event["environment"] == "test"
      assert decoded_event["exception"] == []
      assert decoded_event["extra"] == %{}
      assert decoded_event["user"] == %{}
      assert decoded_event["request"] == %{}
    end

    test "works without an event ID" do
      envelope = Envelope.from_event(Event.create_event([]))
      envelope = %Envelope{envelope | event_id: nil}

      assert {:ok, encoded} = Envelope.to_binary(envelope)

      assert [id_line, _header_line, _event_line] = String.split(encoded, "\n", trim: true)

      assert id_line == "{{}}"
    end

    test "works with attachments" do
      attachments = [
        %Attachment{data: <<1, 2, 3>>, filename: "example.dat"},
        %Attachment{data: "Hello!", filename: "example.txt", content_type: "text/plain"},
        %Attachment{data: "{}", filename: "example.json", content_type: "application/json"},
        %Attachment{data: "...", filename: "dump", attachment_type: "event.minidump"}
      ]

      event = %Event{Event.create_event([]) | attachments: attachments}

      assert {:ok, encoded} = event |> Envelope.from_event() |> Envelope.to_binary()

      assert [
               id_line,
               _event_header,
               _event_data,
               attachment1_header,
               <<1, 2, 3>>,
               attachment2_header,
               "Hello!",
               attachment3_header,
               "{}",
               attachment4_header,
               "..."
             ] = String.split(encoded, "\n", trim: true)

      assert %{"event_id" => _} = decode!(id_line)

      assert decode!(attachment1_header) == %{
               "type" => "attachment",
               "length" => 3,
               "filename" => "example.dat"
             }

      assert decode!(attachment2_header) == %{
               "type" => "attachment",
               "length" => 6,
               "filename" => "example.txt",
               "content_type" => "text/plain"
             }

      assert decode!(attachment3_header) == %{
               "type" => "attachment",
               "length" => 2,
               "filename" => "example.json",
               "content_type" => "application/json"
             }

      assert decode!(attachment4_header) == %{
               "type" => "attachment",
               "length" => 3,
               "filename" => "dump",
               "attachment_type" => "event.minidump"
             }
    end

    test "works with check-ins" do
      put_test_config(environment_name: "test")
      check_in_id = Sentry.UUID.uuid4_hex()
      check_in = %CheckIn{check_in_id: check_in_id, monitor_slug: "test", status: :ok}

      envelope = Envelope.from_check_in(check_in)

      assert {:ok, encoded} = Envelope.to_binary(envelope)

      assert [id_line, header_line, event_line] = String.split(encoded, "\n", trim: true)
      assert %{"event_id" => _} = decode!(id_line)
      assert %{"type" => "check_in", "length" => _} = decode!(header_line)

      decoded_check_in = decode!(event_line)
      assert decoded_check_in["check_in_id"] == check_in_id
      assert decoded_check_in["monitor_slug"] == "test"
      assert decoded_check_in["status"] == "ok"
    end

    test "works with transactions" do
      put_test_config(environment_name: "test")

      root_span =
        %Sentry.Interfaces.Span{
          start_timestamp: 1_588_601_261.481_961,
          timestamp: 1_588_601_261.488_901,
          description: "GET /sockjs-node/info",
          op: "http",
          span_id: "b01b9f6349558cd1",
          parent_span_id: nil,
          trace_id: "1e57b752bc6e4544bbaa246cd1d05dee",
          tags: %{"http.status_code" => "200"},
          data: %{
            "url" => "http://localhost:8080/sockjs-node/info?t=1588601703755",
            "status_code" => 200,
            "type" => "xhr",
            "method" => "GET"
          }
        }

      child_spans =
        [
          %Sentry.Interfaces.Span{
            start_timestamp: 1_588_601_261.535_386,
            timestamp: 1_588_601_261.544_196,
            description: "Vue <App>",
            op: "update",
            span_id: "b980d4dec78d7344",
            parent_span_id: "9312d0d18bf51736",
            trace_id: "1e57b752bc6e4544bbaa246cd1d05dee"
          }
        ]

      transaction =
        Sentry.Transaction.new(%{
          span_id: root_span.span_id,
          spans: [root_span | child_spans],
          transaction: "test-transaction"
        })

      envelope = Envelope.from_transaction(transaction)

      assert {:ok, encoded} = Envelope.to_binary(envelope)

      assert [_id_line, _header_line, transaction_line] = String.split(encoded, "\n", trim: true)

      assert {:ok, decoded_transaction} = Jason.decode(transaction_line)
      assert decoded_transaction["type"] == "transaction"
      assert decoded_transaction["start_timestamp"] == root_span.start_timestamp
      assert decoded_transaction["timestamp"] == root_span.timestamp

      assert [span] = decoded_transaction["spans"]

      assert span["start_timestamp"] == List.first(child_spans).start_timestamp
      assert span["timestamp"] == List.first(child_spans).timestamp
    end
  end

  test "works with client reports" do
    put_test_config(environment_name: "test")

    client_report = %ClientReport{
      timestamp: "2024-10-12T13:21:13",
      discarded_events: [%{reason: :event_processor, category: "error", quantity: 1}]
    }

    envelope = Envelope.from_client_report(client_report)

    assert {:ok, encoded} = Envelope.to_binary(envelope)

    assert [id_line, header_line, event_line] = String.split(encoded, "\n", trim: true)
    assert %{"event_id" => _} = decode!(id_line)
    assert %{"type" => "client_report", "length" => _} = decode!(header_line)

    decoded_client_report = decode!(event_line)
    assert decoded_client_report["timestamp"] == client_report.timestamp

    assert decoded_client_report["discarded_events"] == [
             %{"category" => "error", "reason" => "event_processor", "quantity" => 1}
           ]
  end

  test "returns correct data_category" do
    assert Envelope.get_data_category(%Sentry.Event{
             event_id: Sentry.UUID.uuid4_hex(),
             timestamp: "2024-10-12T13:21:13"
           }) == "error"
  end
end
