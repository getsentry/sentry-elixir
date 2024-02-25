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
  end
end
