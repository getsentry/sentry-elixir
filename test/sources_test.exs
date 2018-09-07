defmodule Sentry.SourcesTest do
  use ExUnit.Case
  use Plug.Test
  import Sentry.TestEnvironmentHelper

  test "exception makes call to Sentry API" do
    Code.compile_string("""
      defmodule SourcesApp do
        use Plug.Router
        use Plug.ErrorHandler
        use Sentry.Plug

        plug :match
        plug :dispatch
        forward("/", to: Sentry.ExampleApp)
      end
    """)

    correct_context = %{
      "context_line" => "    raise RuntimeError, \"Error\"",
      "post_context" => ["  end", "", "  post \"/error_route\" do"],
      "pre_context" => ["", "  get \"/error_route\" do", "    _ = conn"]
    }

    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      frames =
        Jason.decode!(body)
        |> get_in(["stacktrace", "frames"])
        |> Enum.reverse()

      assert ^correct_context =
               Enum.at(frames, 0)
               |> Map.take(["context_line", "post_context", "pre_context"])

      assert body =~ "RuntimeError"
      assert body =~ "ExampleApp"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(RuntimeError, "Error", fn ->
      conn(:get, "/error_route")
      |> SourcesApp.call([])
    end)
  end
end
