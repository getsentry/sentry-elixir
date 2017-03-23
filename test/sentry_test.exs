defmodule SentryTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  test "excludes events properly" do
   Application.put_env(:sentry, :filter, Sentry.TestFilter)


   bypass = Bypass.open
   Bypass.expect bypass, fn conn ->
     {:ok, body, conn} = Plug.Conn.read_body(conn)
     assert body =~ "RuntimeError"
     assert conn.request_path == "/api/1/store/"
     assert conn.method == "POST"
     Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
   end

   Application.put_env(:sentry, :dsn, "http://public:secret@localhost:#{bypass.port}/1")
   Application.put_env(:sentry, :included_environments, [:test])
   Application.put_env(:sentry, :environment_name, :test)

   assert {:ok, _} = Sentry.capture_exception(%RuntimeError{message: "error"}, [event_source: :plug])
   assert :excluded = Sentry.capture_exception(%ArithmeticError{message: "error"}, [event_source: :plug])
   assert {:ok, _} = Sentry.capture_message("RuntimeError: error", [event_source: :plug])
  end

  test "errors when taking too long to receive response" do
   Application.put_env(:sentry, :filter, Sentry.TestFilter)

   bypass = Bypass.open
   Bypass.expect bypass, fn conn ->
     :timer.sleep(100)
     assert conn.request_path == "/api/1/store/"
     assert conn.method == "POST"
     Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
   end
   Bypass.pass(bypass)

   Application.put_env(:sentry, :dsn, "http://public:secret@localhost:#{bypass.port}/1")
   Application.put_env(:sentry, :included_environments, [:test])
   Application.put_env(:sentry, :environment_name, :test)

   assert capture_log(fn ->
     assert :error = Sentry.capture_message("error", [])
   end) =~ "Failed to send Sentry event"
  end
end
