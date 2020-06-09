defmodule Sentry.PlugTest do
  use ExUnit.Case
  use Plug.Test
  import Sentry.TestEnvironmentHelper
  alias Sentry.TestPlugApplications

  test "non-existent route exceptions are ignored" do
    exception = %FunctionClauseError{
      arity: 4,
      function: :do_match,
      module: TestPlugApplications.Example
    }

    assert ^exception =
             assert_raise(
               FunctionClauseError,
               "no function clause matching in Sentry.TestPlugApplications.Example.do_match/4",
               fn ->
                 conn(:get, "/not_found")
                 |> TestPlugApplications.Example.call([])
               end
             )
  end

  test "overriding handle_errors/2" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    conn = conn(:post, "/error_route", %{})

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      TestPlugApplications.Override.call(conn, [])
    end)

    assert {500, _headers, "Something went terribly wrong"} = sent_resp(conn)
  end

  test "default data scrubbing" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["request"]["cookies"] == %{}
      assert json["request"]["headers"] == %{"content-type" => "application/json"}
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
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
      |> TestPlugApplications.DefaultConfig.call([])
    end)
  end

  test "handles data scrubbing with file upload" do
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

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:post, "/error_route", %{"image" => upload, "password" => "my_password"})
      |> put_req_cookie("cookie_key", "cookie_value")
      |> put_req_header("accept-language", "en-US")
      |> put_req_header("authorization", "ignorme")
      |> TestPlugApplications.ScrubbingWithFile.call([])
    end)
  end

  test "custom cookie scrubbing" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["request"]["cookies"] == %{"regular" => "value"}
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> update_req_cookie("secret", "secretvalue")
      |> update_req_cookie("regular", "value")
      |> TestPlugApplications.CustomCookieScrubber.call([])
    end)
  end

  test "collects feedback" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, _body, _conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    conn =
      conn(:get, "/error_route")
      |> Plug.Conn.put_req_header("accept", "text/html")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      TestPlugApplications.CollectFeedback.call(conn, [])
    end)

    assert_received {:plug_conn, :sent}
    assert {500, _headers, body} = sent_resp(conn)
    assert body =~ "340"
    assert body =~ "sentry-cdn"
    assert body =~ ~s{"title":"abc-123"}
  end

  test "request url" do
    # Default ports
    conn = conn(:get, "http://www.example.com:80/error_route")
    %{url: url} = Sentry.Plug.build_request_interface_data(conn, [])
    assert url == "http://www.example.com/error_route"

    conn = conn(:get, "https://www.example.com:443/error_route")
    %{url: url} = Sentry.Plug.build_request_interface_data(conn, [])
    assert url == "https://www.example.com/error_route"

    # Custom ports
    conn = conn(:get, "http://www.example.com:1234/error_route")
    %{url: url} = Sentry.Plug.build_request_interface_data(conn, [])
    assert url == "http://www.example.com:1234/error_route"

    conn = conn(:get, "https://www.example.com:1234/error_route")
    %{url: url} = Sentry.Plug.build_request_interface_data(conn, [])
    assert url == "https://www.example.com:1234/error_route"
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
