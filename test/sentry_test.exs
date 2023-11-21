defmodule SentryTest do
  use Sentry.Case
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
    put_test_config(dsn: "http://public:secret@localhost:#{bypass.port}/1", dedup_events: false)
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

  @tag :capture_log
  test "errors when taking too long to receive response", %{bypass: bypass} do
    Bypass.expect(bypass, fn _conn -> Process.sleep(:infinity) end)

    put_test_config(hackney_opts: [recv_timeout: 50])

    assert {:error, {:request_failure, :timeout}} =
             Sentry.capture_message("error", request_retries: [], result: :sync)

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
    parent_pid = self()
    ref = make_ref()

    put_test_config(
      enable_source_code_context: true,
      root_source_code_paths: [File.cwd!()],
      source_code_path_pattern: "{lib,test}/*.{ex,exs}"
    )

    set_mix_shell(Mix.Shell.Quiet)

    assert :ok = Mix.Task.rerun("sentry.package_source_code")

    assert {:loaded, _source_map} = Sentry.Sources.load_source_code_map_if_present()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      event = decode_event_from_envelope!(body)
      send(parent_pid, {ref, event})
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

    assert {:ok, "340"} =
             Sentry.capture_exception(%RuntimeError{message: "oops"},
               stacktrace: stacktrace,
               result: :sync
             )

    assert_receive {^ref, event}

    [exception] = event.exception
    assert exception["type"] == "RuntimeError"
    assert exception["value"] == "oops"

    assert [%{"function" => "Process.info/2"}, interesting_frame | _rest] =
             Enum.reverse(exception["stacktrace"]["frames"])

    assert interesting_frame["context_line"] =~ "Process.info(self(), :current_stacktrace)"
    assert Enum.at(interesting_frame["pre_context"], 0) =~ "Plug.Conn.resp(conn"
    assert Enum.at(interesting_frame["pre_context"], 1) =~ "end)"
    assert Enum.at(interesting_frame["post_context"], 0) == ""
    assert Enum.at(interesting_frame["post_context"], 1) =~ "assert {:ok, "
  end
end
