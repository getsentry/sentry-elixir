defmodule Sentry.PlugTest do
  use ExUnit.Case
  use Plug.Test
  import Sentry.TestEnvironmentHelper

  test "non-existent route exceptions are ignored" do
    exception = %FunctionClauseError{arity: 4,
                                     function: :do_match,
                                     module: Sentry.ExampleApp}


    assert ^exception = assert_raise(FunctionClauseError, "no function clause matching in Sentry.ExampleApp.do_match/4", fn ->
      conn(:get, "/not_found")
      |> Sentry.ExampleApp.call([])
    end)
  end

  test "exception makes call to Sentry API" do
    bypass = Bypass.open
    Bypass.expect bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "RuntimeError"
      assert body =~ "ExampleApp"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(RuntimeError, "Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.ExampleApp.call([])
    end)
  end

  test "builds request data" do
    conn = conn(:get, "/error_route?key=value")
           |> put_req_cookie("cookie_key", "cookie_value")
           |> put_req_header("accept-language", "en-US")

    request_data = Sentry.Plug.build_request_interface_data(conn, [header_scrubber: &Sentry.Plug.default_header_scrubber/1])

    assert request_data[:url] =~ ~r/\/error_route$/
    assert request_data[:method] == "GET"
    assert request_data[:data] == %{}
    assert request_data[:headers] == %{"cookie" => "cookie_key=cookie_value", "accept-language" => "en-US"}
    assert request_data[:cookies] == %{"cookie_key" => "cookie_value"}
    assert request_data[:query_string] == "key=value"
    assert is_binary(request_data[:env]["REMOTE_ADDR"])
    assert is_integer(request_data[:env]["REMOTE_PORT"])
    assert is_binary(request_data[:env]["SERVER_NAME"])
    assert is_integer(request_data[:env]["SERVER_PORT"])
  end

  test "handles data scrubbing" do
    conn = conn(:post, "/error_route", %{
      "hello" => "world",
      "password" => "test",
      "cc" => "4242424242424242"})
    |> put_req_cookie("cookie_key", "cookie_value")
    |> put_req_header("accept-language", "en-US")
    |> put_req_header("authorization", "ignorme")

    scrubber = fn conn ->
      conn.params
      |> Enum.filter(fn {key, val} -> 
        !(key in ~w(password passwd secret credit_card) ||
        Regex.match?(~r/^(?:\d[ -]*?){13,16}$/, val)) # Matches Credit Cards
      end)
      |> Enum.into(%{})
    end

    options = [body_scrubber: scrubber, header_scrubber: &Sentry.Plug.default_header_scrubber/1]
    request_data = Sentry.Plug.build_request_interface_data(conn, options)
    assert request_data[:method] == "POST"
    assert request_data[:data] == %{"hello" => "world"}
    assert request_data[:headers] == %{"cookie" => "cookie_key=cookie_value", "accept-language" => "en-US", "content-type" => "multipart/mixed; charset: utf-8"}
    assert request_data[:cookies] == %{"cookie_key" => "cookie_value"}
  end

  test "gets request_id" do
    conn = conn(:get, "/error_route")
           |> Plug.Conn.put_resp_header("x-request-id", "my_request_id")

    request_data = Sentry.Plug.build_request_interface_data(conn, [request_id_header: "x-request-id"])
    assert request_data[:env]["REQUEST_ID"] == "my_request_id"
  end

  test "default data scrubbing" do
    conn = conn(:post, "/error_route", %{
      "secret" => "world",
      "password" => "test",
      "passwd" => "4242424242424242",
      "credit_card" => "4197 7215 7810 8280",
      "count" => 334,
      "is_admin" => false,
      "cc" => "4197-7215-7810-8280",
      "another_cc" => "4197721578108280",
      "user" => %{"password" => "mypassword"}})

    request_data = Sentry.Plug.build_request_interface_data(conn, body_scrubber: &Sentry.Plug.default_body_scrubber/1)
    assert request_data[:method] == "POST"
    assert request_data[:data] == %{"secret" => "*********", "password" => "*********", "count" => 334,
      "is_admin" => false, "passwd" => "*********", "credit_card" => "*********", "cc" => "*********",
      "another_cc" => "*********", "user" => %{"password" => "*********"}}
  end
end
