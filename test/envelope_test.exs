defmodule Sentry.EnvelopeTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.{Attachment, Envelope, Event}

  describe "new/1" do
    test "raises if there are no items" do
      assert_raise FunctionClauseError, fn ->
        Envelope.new([])
      end
    end

    test "raises if there are no events" do
      assert_raise ArgumentError, "cannot construct an envelope without an event", fn ->
        Envelope.new([%Attachment{filename: "example.txt", data: "example"}])
      end
    end

    test "raises if there are multiple events" do
      assert_raise ArgumentError, "cannot construct an envelope with multiple events", fn ->
        Envelope.new([Event.create_event([]), Event.create_event([])])
      end
    end
  end

  describe "to_binary/1" do
    test "encodes an envelope" do
      put_test_config(environment_name: "test")
      event = Event.create_event([])

      envelope = Envelope.new([event])

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
      envelope = Envelope.new([Event.create_event([])])
      envelope = %Envelope{envelope | event_id: nil}

      assert {:ok, encoded} = Envelope.to_binary(envelope)

      assert [id_line, _header_line, _event_line] = String.split(encoded, "\n", trim: true)

      assert id_line == "{{}}"
    end

    test "works with attachments" do
      envelope =
        Envelope.new([
          %Attachment{data: <<1, 2, 3>>, filename: "example.dat"},
          %Attachment{data: "Hello!", filename: "example.txt", content_type: "text/plain"},
          %Attachment{data: "{}", filename: "example.json", content_type: "application/json"},
          %Attachment{data: "...", filename: "dump", attachment_type: "event.minidump"},
          Event.create_event([])
        ])

      assert {:ok, encoded} = Envelope.to_binary(envelope)

      assert [
               id_line,
               attachment1_header,
               <<1, 2, 3>>,
               attachment2_header,
               "Hello!",
               attachment3_header,
               "{}",
               attachment4_header,
               "...",
               _event_header,
               _event_data
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
  end
end
