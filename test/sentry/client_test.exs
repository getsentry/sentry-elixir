defmodule Sentry.ClientTest do
  use Sentry.Case

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  alias Sentry.{Client, Event}

  describe "render_event/1" do
    test "transforms structs into maps" do
      event = Event.transform_exception(%RuntimeError{message: "foo"}, user: %{id: 1})

      assert %{
               user: %{id: 1},
               exception: [%{type: "RuntimeError", value: "foo"}],
               sdk: %{name: "sentry-elixir"}
             } = Client.render_event(event)
    end

    test "renders :release field" do
      put_test_config(release: "1.9.123")
      event = Event.create_event([])

      assert %{release: "1.9.123"} = Client.render_event(event)
    end

    test "truncates the message to a max length" do
      max_length = 8_192
      event = Event.create_event(message: String.duplicate("a", max_length + 1))
      assert Client.render_event(event).message.formatted == String.duplicate("a", max_length)
    end

    test "safely inspects terms that cannot be converted to JSON" do
      event =
        Event.create_event(
          extra: %{
            valid: "yes",
            self: self(),
            keyword: [key: "value"],
            nested: %{self: self()},
            bool: true,
            null: nil,
            int: 2,
            map: %{bool: false}
          },
          user: %{id: "valid-ID", email: {"user", "@example.com"}},
          tags: %{valid: "yes", tokens: MapSet.new([1])}
        )

      rendered = Client.render_event(event)

      assert rendered.extra.valid == "yes"
      assert rendered.extra.self == inspect(self())
      assert rendered.extra.keyword == [~s({:key, "value"})]
      assert rendered.extra.nested.self == inspect(self())
      assert rendered.extra.bool == true
      assert rendered.extra.null == nil
      assert rendered.extra.int == 2
      assert rendered.extra.map.bool == false

      assert rendered.user.id == "valid-ID"
      assert rendered.user.email == ~s({"user", "@example.com"})

      assert rendered.tags.valid == "yes"
      assert rendered.tags.tokens == inspect(MapSet.new([1]))
    end

    test "works if the JSON library crashes" do
      defmodule RaisingJSONClient do
        def encode(:crash), do: raise("Oops")
        def encode(term), do: Jason.encode(term)

        def decode(term), do: Jason.decode(term)
      end

      put_test_config(json_library: RaisingJSONClient)

      event = Event.create_event(message: "Something went wrong", extra: %{crasher: :crash})

      assert %{} = rendered = Client.render_event(event)
      assert rendered.extra.crasher == ":crash"
    after
      :code.delete(RaisingJSONClient)
      :code.purge(RaisingJSONClient)
    end
  end

  describe "send_event/2" do
    setup do
      bypass = Bypass.open()
      put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")
      %{bypass: bypass}
    end

    test "respects the :sample_rate option", %{bypass: bypass} do
      # Always sends with sample rate of 1.
      Bypass.expect_once(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      assert {:ok, "340"} = Client.send_event(Event.create_event([]), sample_rate: 1.0)

      # Never sends with sample rate of 0.
      assert :unsampled = Client.send_event(Event.create_event([]), sample_rate: 0.0)

      # Either sends or doesn't with :sample_rate of 0.5.
      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      for _ <- 1..10 do
        event = Event.create_event(message: "Unique: #{System.unique_integer()}")
        result = Client.send_event(event, sample_rate: 0.5)
        assert match?({:ok, _}, result) or result == :unsampled
      end
    end

    test "calls anonymous :before_send callback", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert [{%{"type" => "event"}, event}] = decode_envelope!(body)

        assert event["extra"] == %{"key" => "value"}
        assert event["user"]["id"] == 1

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      put_test_config(
        before_send: fn event ->
          metadata = Map.new(Logger.metadata())
          {user_id, rest_metadata} = Map.pop(metadata, :user_id)

          %Event{
            event
            | extra: Map.merge(event.extra, rest_metadata),
              user: Map.put(event.user, :id, user_id)
          }
        end
      )

      event = Event.create_event([])
      Logger.metadata(key: "value", user_id: 1)

      assert {:ok, _} = Client.send_event(event, result: :sync)
    end

    test "if :before_send callback returns falsey, the event is not sent" do
      defmodule CallbackModuleArithmeticError do
        def before_send(event) do
          case event.original_exception do
            %ArithmeticError{} -> false
            _ -> event
          end
        end
      end

      put_test_config(before_send: {CallbackModuleArithmeticError, :before_send})

      try do
        :rand.uniform() + "1"
      rescue
        exception ->
          event = Event.transform_exception(exception, _opts = [])
          assert Client.send_event(event, result: :sync) == :excluded
      end
    after
      :code.delete(CallbackModuleArithmeticError)
      :code.purge(CallbackModuleArithmeticError)
    end

    test "calls the :before_send callback before using the sample rate and sets the session" do
      test_pid = self()
      ref = make_ref()
      event = Event.create_event(event_source: :plug)

      put_test_config(
        before_send: fn event ->
          send(test_pid, {ref, event})
          event
        end
      )

      assert :unsampled = Client.send_event(event, sample_rate: 0.0)
      assert_received {^ref, ^event}
      assert Sentry.get_last_event_id_and_source() == {event.event_id, event.source}
    end

    test "calls anonymous :after_send_event callback synchronously",
         %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      test_pid = self()
      ref = make_ref()

      put_test_config(
        after_send_event: fn event, result -> send(test_pid, {ref, event, result}) end
      )

      event = Event.create_event(message: "Something went wrong")
      assert {:ok, _} = Client.send_event(event, result: :sync)
      assert_received {^ref, ^event, {:ok, _id}}
    end

    test "logs API errors at the configured level", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("X-Sentry-Error", "Rate limiting.")
        |> Plug.Conn.resp(400, "{}")
      end)

      put_test_config(log_level: :info)

      event = Event.create_event(message: "Something went wrong")

      log =
        capture_log(fn ->
          Client.send_event(event, result: :sync, request_retries: [])
        end)

      assert log =~ "[info]"
      assert log =~ "Failed to send Sentry event."
      assert log =~ "Received 400 from Sentry server: Rate limiting."
    end

    test "logs an error when unable to encode JSON" do
      defmodule BadJSONClient do
        def encode(term) when term == %{}, do: {:ok, "{}"}
        def encode(_term), do: {:error, :im_just_bad}

        def decode(term), do: Jason.decode(term)
      end

      put_test_config(json_library: BadJSONClient)
      event = Event.create_event(message: "Something went wrong")

      assert capture_log(fn ->
               Client.send_event(event, result: :sync)
             end) =~ "Failed to send Sentry event. Unable to encode JSON"
    end

    test "uses the async sender pool when :result is :none", %{bypass: bypass} do
      test_pid = self()
      ref = make_ref()

      Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {ref, body})
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      event = Event.create_event(message: "Something went wrong")
      assert {:ok, ""} = Client.send_event(event, result: :none)

      event =
        fn ->
          assert_receive {^ref, body}, 1000
          assert [{%{"type" => "event"}, event}] = decode_envelope!(body)
          event
        end
        |> Stream.repeatedly()
        |> Stream.reject(&is_nil/1)
        |> Stream.take(10)
        |> Enum.at(0)

      assert event["message"] == %{
               "formatted" => "Something went wrong",
               "message" => nil,
               "params" => nil
             }
    end

    test "dedupes events", %{bypass: bypass} do
      put_test_config(dedup_events: true)

      {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

      events = [
        Event.create_event(message: "Dedupes by message")
        |> Tuple.duplicate(2),
        Event.create_event(exception: %RuntimeError{message: "Dedupes by exception"})
        |> Tuple.duplicate(2),
        Event.create_event(message: "Dedupes by message and stacktrace", stacktrace: stacktrace)
        |> Tuple.duplicate(2),
        {
          Event.create_event(
            message: "Same message but diff extra",
            user: %{id: 1},
            request: %{method: :GET}
          ),
          Event.create_event(
            message: "Same message but diff extra",
            user: %{id: 2},
            request: %{method: :POST}
          )
        }
      ]

      for {event, dup_event} <- events do
        Bypass.expect_once(bypass, fn conn ->
          Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
        end)

        assert {:ok, "340"} = Client.send_event(event, [])

        log =
          capture_log(fn ->
            assert :excluded = Client.send_event(dup_event, [])
          end)

        assert log =~ "Event dropped due to being a duplicate of a previously-captured event."
      end
    end
  end
end
