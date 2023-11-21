defmodule SentryTest do
  use ExUnit.Case
  use Plug.Test

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  defmodule TestFilter do
    @behaviour Sentry.EventFilter

    def exclude_exception?(%ArithmeticError{}, :plug), do: true
    def exclude_exception?(_, _), do: false
  end

  setup do
    bypass = Bypass.open()
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1")
    %{bypass: bypass}
  end

  test "excludes events properly", %{bypass: bypass} do
    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "RuntimeError"
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(filter: TestFilter)

    assert {:ok, _} =
             Sentry.capture_exception(
               %RuntimeError{message: "error"},
               event_source: :plug,
               result: :sync
             )

    assert :excluded =
             Sentry.capture_exception(
               %ArithmeticError{message: "error"},
               event_source: :plug,
               result: :sync
             )

    assert {:ok, _} =
             Sentry.capture_message("RuntimeError: error", event_source: :plug, result: :sync)
  end

  test "errors when taking too long to receive response", %{bypass: bypass} do
    Bypass.expect(bypass, fn _conn -> Process.sleep(:infinity) end)

    put_test_config(hackney_opts: [recv_timeout: 50])

    capture_log(fn ->
      assert {:error, {:request_failure, :timeout}} =
               Sentry.capture_message("error", request_retries: [])
    end)

    Bypass.pass(bypass)
  end

  test "sets last_event_id_and_source when an event is sent", %{bypass: bypass} do
    Bypass.expect(bypass, fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    Sentry.capture_message("test")

    assert {event_id, nil} = Sentry.get_last_event_id_and_source()
    assert is_binary(event_id)
  end

  test "ignores events without message and exception" do
    log =
      capture_log(fn ->
        assert Sentry.send_event(Sentry.Event.create_event([])) == :ignored
      end)

    assert log =~ "Sentry: unable to parse exception"
  end

  test "reports source code context", %{bypass: bypass} do
    put_test_config(enable_source_code_context: true, root_source_code_paths: [File.cwd!()])
    set_mix_shell(Mix.Shell.Quiet)

    Mix.Task.rerun("sentry.package_source_code", ["--debug"])

    :ok = Sentry.Sources.load_source_code_map_if_present()

    correct_context = %{
      "context_line" => "    raise RuntimeError, \"Error\"",
      "post_context" => ["  end", "", "  get \"/exit_route\" do"],
      "pre_context" => ["", "  get \"/error_route\" do", "    _ = conn"]
    }

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event = decode_event_from_envelope!(body)

      frames = Enum.reverse(List.first(event.exception)["stacktrace"]["frames"])

      assert ^correct_context =
               Enum.at(frames, 0)
               |> Map.take(["context_line", "post_context", "pre_context"])

      assert body =~ "RuntimeError"
      assert body =~ "Example"
      assert conn.request_path == "/api/1/envelope/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.ExamplePlugApplication.call([])
    end)
  end
end
