defmodule Sentry.PlugTest do
  use ExUnit.Case
  use Plug.Test
  import Sentry.TestEnvironmentHelper

  test "non-existent route exceptions are ignored" do
    exception = %FunctionClauseError{arity: 4, function: :do_match, module: Sentry.ExampleApp}

    assert ^exception =
             assert_raise(
               FunctionClauseError,
               "no function clause matching in Sentry.ExampleApp.do_match/4",
               fn ->
                 conn(:get, "/not_found")
                 |> Sentry.ExampleApp.call([])
               end
             )
  end

  test "overriding handle_errors/2" do
    Code.compile_string("""
      defmodule OverrideApp do
        use Plug.Router
        use Plug.ErrorHandler
        use Sentry.Plug
        plug :match
        plug :dispatch
        forward("/", to: Sentry.ExampleApp)

        defp handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack} = error) do
          super(conn, error)
          send_resp(conn, conn.status, "Something went terribly wrong")
        end
      end
    """)

    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    conn = conn(:post, "/error_route", %{})

    assert_raise(RuntimeError, "Error", fn ->
      OverrideApp.call(conn, [])
    end)

    assert {500, _headers, "Something went terribly wrong"} = sent_resp(conn)
  end

  test "default data scrubbing" do
    Code.compile_string("""
      defmodule DefaultConfigApp do
        use Plug.Router
        use Plug.ErrorHandler
        use Sentry.Plug
        plug :match
        plug :dispatch
        forward("/", to: Sentry.ExampleApp)
      end
    """)

    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["request"]["cookies"] == %{}
      assert json["request"]["headers"] == %{"content-type" => "application/json"}
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(RuntimeError, "Error", fn ->
      conn(:post, "/error_route", %{
        "secret" => "world",
        "password" => "test",
        "passwd" => "4242424242424242",
        "credit_card" => "4197 7215 7810 8280",
        "count" => 334,
        "cc" => "4197-7215-7810-8280",
        "another_cc" => "4197721578108280",
        "user" => %{"password" => "mypassword"}
      })
      |> update_req_cookie("secret", "secretvalue")
      |> update_req_cookie("regular", "value")
      |> put_req_header("authorization", "secrets")
      |> put_req_header("authentication", "secrets")
      |> put_req_header("content-type", "application/json")
      |> DefaultConfigApp.call([])
    end)
  end

  test "handles data scrubbing with file upload" do
    Code.compile_string("""
      defmodule ScrubbingWithFileApp do
        use Plug.Router
        use Plug.ErrorHandler
        use Sentry.Plug
        plug :match
        plug :dispatch
        forward("/", to: Sentry.ExampleApp)
      end
    """)

    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert is_map(json["request"]["data"]["image"])
      assert json["request"]["data"]["password"] == "*********"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")
    upload = %Plug.Upload{path: "test/fixtures/my_image.png", filename: "my_image.png"}

    assert_raise(RuntimeError, "Error", fn ->
      conn(:post, "/error_route", %{"image" => upload, "password" => "my_password"})
      |> put_req_cookie("cookie_key", "cookie_value")
      |> put_req_header("accept-language", "en-US")
      |> put_req_header("authorization", "ignorme")
      |> ScrubbingWithFileApp.call([])
    end)
  end

  test "custom cookie scrubbing" do
    Code.compile_string("""
      defmodule CustomCookieScrubberApp do
        use Plug.Router
        use Plug.ErrorHandler
        use Sentry.Plug, cookie_scrubber: fn(conn) ->
          Map.take(conn.req_cookies, ["regular"])
        end
        plug :match
        plug :dispatch
        forward("/", to: Sentry.ExampleApp)
      end
    """)

    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["request"]["cookies"] == %{"regular" => "value"}
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(RuntimeError, "Error", fn ->
      conn(:get, "/error_route")
      |> update_req_cookie("secret", "secretvalue")
      |> update_req_cookie("regular", "value")
      |> CustomCookieScrubberApp.call([])
    end)
  end

  defp update_req_cookie(conn, name, value) do
    req_headers =
      conn.req_headers
      |> Enum.into(%{})
      |> Map.update("cookie", "#{name}=#{value}", fn val ->
        Plug.Conn.Cookies.decode(val)
        |> Map.put(name, value)
        |> Enum.map(fn {cookie_name, cookie_value} ->
          "#{cookie_name}=#{cookie_value}"
        end)
        |> Enum.join("; ")
      end)
      |> Enum.into([])

    %Plug.Conn{conn | req_headers: req_headers}
  end
end
