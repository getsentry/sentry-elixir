defmodule Sentry.EnvelopeTest do
  use Sentry.Case, async: false

  import Sentry.TestHelpers

  alias Sentry.{Envelope, Event}

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
  end
end
