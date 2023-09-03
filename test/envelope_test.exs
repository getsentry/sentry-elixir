defmodule Sentry.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Sentry.{Envelope, Event}

  describe "from_binary/1" do
    test "parses envelope with empty headers" do
      raw = "{}\n"

      {:ok, envelope} = Envelope.from_binary(raw)

      assert envelope.event_id == nil
      assert envelope.items == []
    end

    test "parses envelope with only headers" do
      raw = "{\"event_id\":\"12c2d058d58442709aa2eca08bf20986\"}\n"

      {:ok, envelope} = Envelope.from_binary(raw)

      assert envelope.event_id == "12c2d058d58442709aa2eca08bf20986"
      assert envelope.items == []
    end

    test "parses envelope containing an event" do
      event = %Event{
        breadcrumbs: [],
        environment: :test,
        event_id: "1d208b37d9904203918a9c2125ea91fa",
        __source__: nil,
        exception: nil,
        extra: %{},
        fingerprint: ["{{ default }}"],
        level: "error",
        message: "hello",
        modules: %{
          bypass: "2.1.0",
          certifi: "2.6.1",
          cowboy: "2.8.0",
          cowboy_telemetry: "0.3.1",
          cowlib: "2.9.1",
          dialyxir: "1.1.0",
          erlex: "0.2.6",
          hackney: "1.17.4",
          idna: "6.1.1",
          jason: "1.2.2",
          metrics: "1.0.1",
          mime: "1.5.0",
          mimerl: "1.2.0",
          parse_trans: "3.3.1",
          phoenix: "1.5.8",
          phoenix_html: "2.14.3",
          phoenix_pubsub: "2.0.0",
          plug: "1.11.1",
          plug_cowboy: "2.4.1",
          plug_crypto: "1.2.2",
          ranch: "1.7.1",
          ssl_verify_fun: "1.1.6",
          telemetry: "0.4.2",
          unicode_util_compat: "0.7.0"
        },
        __original_exception__: nil,
        platform: :elixir,
        release: nil,
        request: %{},
        server_name: "john-linux",
        tags: %{},
        timestamp: "2021-10-09T03:53:22",
        user: %{}
      }

      {:ok, raw_envelope} =
        [event]
        |> Sentry.Envelope.new()
        |> Sentry.Envelope.to_binary()

      {:ok, envelope} = Envelope.from_binary(raw_envelope)

      assert envelope.event_id == event.event_id

      assert envelope.items == [
               %Event{
                 breadcrumbs: [],
                 environment: "test",
                 event_id: "1d208b37d9904203918a9c2125ea91fa",
                 exception: nil,
                 extra: %{},
                 fingerprint: ["{{ default }}"],
                 level: "error",
                 message: "hello",
                 modules: %{
                   "bypass" => "2.1.0",
                   "certifi" => "2.6.1",
                   "cowboy" => "2.8.0",
                   "cowboy_telemetry" => "0.3.1",
                   "cowlib" => "2.9.1",
                   "dialyxir" => "1.1.0",
                   "erlex" => "0.2.6",
                   "hackney" => "1.17.4",
                   "idna" => "6.1.1",
                   "jason" => "1.2.2",
                   "metrics" => "1.0.1",
                   "mime" => "1.5.0",
                   "mimerl" => "1.2.0",
                   "parse_trans" => "3.3.1",
                   "phoenix" => "1.5.8",
                   "phoenix_html" => "2.14.3",
                   "phoenix_pubsub" => "2.0.0",
                   "plug" => "1.11.1",
                   "plug_cowboy" => "2.4.1",
                   "plug_crypto" => "1.2.2",
                   "ranch" => "1.7.1",
                   "ssl_verify_fun" => "1.1.6",
                   "telemetry" => "0.4.2",
                   "unicode_util_compat" => "0.7.0"
                 },
                 platform: "elixir",
                 release: nil,
                 request: %{},
                 server_name: "john-linux",
                 tags: %{},
                 timestamp: "2021-10-09T03:53:22",
                 user: %{}
               }
             ]
    end
  end

  describe "to_binary/1" do
    test "encodes an envelope" do
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
      assert decoded_event["exception"] == nil
      assert decoded_event["extra"] == %{}
      assert decoded_event["user"] == %{}
      assert decoded_event["request"] == %{}
    end
  end
end
