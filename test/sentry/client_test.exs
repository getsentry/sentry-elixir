defmodule Sentry.ClientTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  import Sentry.TestEnvironmentHelper

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

    test "truncates the message to a max length" do
      max_length = 8_192
      event = Event.create_event(message: String.duplicate("a", max_length + 1))
      assert Client.render_event(event).message == String.duplicate("a", max_length)
    end

    test "safely inspects terms that cannot be converted to JSON" do
      event =
        Event.create_event(
          extra: %{
            valid: "yes",
            self: self(),
            keyword: [key: "value"],
            nested: %{self: self()}
          },
          user: %{id: "valid-ID", email: {"user", "@example.com"}},
          tags: %{valid: "yes", tokens: MapSet.new([1])}
        )

      rendered = Client.render_event(event)

      assert rendered.extra.valid == "yes"
      assert rendered.extra.self == inspect(self())
      assert rendered.extra.keyword == [~s({:key, "value"})]
      assert rendered.extra.nested.self == inspect(self())

      assert rendered.user.id == "valid-ID"
      assert rendered.user.email == ~s({"user", "@example.com"})

      assert rendered.tags.valid == "yes"
      assert rendered.tags.tokens == inspect(MapSet.new([1]))
    end
  end

  describe "send_event/2" do
    setup do
      bypass = Bypass.open()
      modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
      %{bypass: bypass}
    end

    test "respects the :sample_rate option", %{bypass: bypass} do
      event = Event.create_event([])

      # Always sends with sample rate of 1.
      Bypass.expect_once(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      assert {:ok, "340"} = Client.send_event(event, sample_rate: 1.0)

      # Never sends with sample rate of 0.
      assert :unsampled = Client.send_event(event, sample_rate: 0.0)

      # Either sends or doesn't with :sample_rate of 0.5.
      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      for _ <- 1..10 do
        result = Client.send_event(event, sample_rate: 0.5)
        assert match?({:ok, _}, result) or result == :unsampled
      end
    end

    test "calls anonymous :before_send callback", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)

        event = TestHelpers.decode_event_from_envelope!(body)

        assert event.extra == %{"key" => "value"}
        assert event.user["id"] == 1

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      modify_env(
        :sentry,
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

    # TODO: Remove in v11.0.0, :before_send_event has been deprecated in v10.0.0.
    test "still supports :before_send_event callback", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)

        event = TestHelpers.decode_event_from_envelope!(body)

        assert event.extra == %{"key" => "value"}
        assert event.user["id"] == 1

        Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
      end)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          modify_env(
            :sentry,
            before_send_event: fn event ->
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
        end)

      assert stderr =~ ":before_send_event option is deprecated. Use :before_send instead."
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

      modify_env(:sentry, before_send: {CallbackModuleArithmeticError, :before_send})

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
      event = Event.create_event(source: :plug)

      modify_env(:sentry,
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

      modify_env(
        :sentry,
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

      modify_env(:sentry, log_level: :info)

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

      modify_env(:sentry, json_library: BadJSONClient)

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
          TestHelpers.decode_event_from_envelope!(body)
        end
        |> Stream.repeatedly()
        |> Stream.reject(&is_nil/1)
        |> Stream.take(10)
        |> Enum.at(0)

      assert %Event{} = event
      assert event.message == "Something went wrong"
    end
  end
end
