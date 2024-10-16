defmodule Sentry.EnvelopeTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.{Attachment, CheckIn, Envelope, Event}

  describe "to_binary/1" do
    test "encodes an envelope" do
      put_test_config(environment_name: "test")
      event = Event.create_event([])

      envelope = Envelope.from_event(event)

      assert {:ok, encoded} = Envelope.to_binary(envelope)

      assert [id_line, header_line, event_line] = String.split(encoded, "\n", trim: true)
      assert Jason.decode!(id_line) == %{"event_id" => event.event_id}
      assert %{"type" => "event", "length" => _} = Jason.decode!(header_line)

      assert {:ok, decoded_event} = Jason.decode(event_line)
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

      assert %{"event_id" => _} = Jason.decode!(id_line)

      assert Jason.decode!(attachment1_header) == %{
               "type" => "attachment",
               "length" => 3,
               "filename" => "example.dat"
             }

      assert Jason.decode!(attachment2_header) == %{
               "type" => "attachment",
               "length" => 6,
               "filename" => "example.txt",
               "content_type" => "text/plain"
             }

      assert Jason.decode!(attachment3_header) == %{
               "type" => "attachment",
               "length" => 2,
               "filename" => "example.json",
               "content_type" => "application/json"
             }

      assert Jason.decode!(attachment4_header) == %{
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
      assert %{"event_id" => _} = Jason.decode!(id_line)
      assert %{"type" => "check_in", "length" => _} = Jason.decode!(header_line)

      assert {:ok, decoded_check_in} = Jason.decode(event_line)
      assert decoded_check_in["check_in_id"] == check_in_id
      assert decoded_check_in["monitor_slug"] == "test"
      assert decoded_check_in["status"] == "ok"
    end

    test "works with transactions" do
      put_test_config(environment_name: "test")

      spans = [
        %Sentry.Span{
          start_timestamp: 1_588_601_261.481_961,
          timestamp: 1_588_601_261.488_901,
          description: "GET /sockjs-node/info",
          op: "http",
          span_id: "b01b9f6349558cd1",
          parent_span_id: "b0e6f15b45c36b12",
          trace_id: "1e57b752bc6e4544bbaa246cd1d05dee",
          tags: %{"http.status_code" => "200"},
          data: %{
            "url" => "http://localhost:8080/sockjs-node/info?t=1588601703755",
            "status_code" => 200,
            "type" => "xhr",
            "method" => "GET"
          }
        },
        %Sentry.Span{
          start_timestamp: 1_588_601_261.535_386,
          timestamp: 1_588_601_261.544_196,
          description: "Vue <App>",
          op: "update",
          span_id: "b980d4dec78d7344",
          parent_span_id: "9312d0d18bf51736",
          trace_id: "1e57b752bc6e4544bbaa246cd1d05dee"
        }
      ]

      transaction = %Sentry.Transaction{
        start_timestamp: System.system_time(:second),
        timestamp: System.system_time(:second),
        spans: spans
      }

      envelope = Envelope.from_transaction(transaction)

      assert {:ok, encoded} = Envelope.to_binary(envelope)

      assert [_id_line, _header_line, transaction_line] = String.split(encoded, "\n", trim: true)

      assert {:ok, decoded_transaction} = Jason.decode(transaction_line)
      assert decoded_transaction["type"] == "transaction"
      assert decoded_transaction["start_timestamp"] == transaction.start_timestamp
      assert decoded_transaction["timestamp"] == transaction.timestamp

      assert [span1, span2] = decoded_transaction["spans"]

      assert span1["start_timestamp"] == List.first(spans).start_timestamp
      assert span1["timestamp"] == List.first(spans).timestamp

      assert span2["start_timestamp"] == List.last(spans).start_timestamp
      assert span2["timestamp"] == List.last(spans).timestamp
    end
  end
end
