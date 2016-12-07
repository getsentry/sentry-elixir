defmodule SentryTest do
  use ExUnit.Case

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

   Sentry.capture_exception(%RuntimeError{message: "error"}, [event_source: :plug])
   Sentry.capture_exception(%ArithmeticError{message: "error"}, [event_source: :plug])
  end
end
