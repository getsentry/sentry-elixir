defmodule Sentry.PlugTest do
  use ExUnit.Case, async: true
  use Plug.Test

  defmodule ExampleApp do
    use Plug.Router
    use Plug.ErrorHandler
    use Sentry.Plug, request_id_header: "x-request-id"


    plug Plug.Parsers, parsers: [:multipart]
    plug Plug.RequestId
    plug :match
    plug :dispatch

    get "/error_route" do
      _ = conn
      raise RuntimeError, "Error"
    end

    match "/error_route" do
      _ = conn
      raise RuntimeError, "Error"
    end

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
   Application.put_env(:sentry, :dsn, "http://public:secret@localhost:#{bypass.port}/1")
   Application.put_env(:sentry, :included_environments, [:test])
   Application.put_env(:sentry, :environment_name, :test)

   assert_raise(RuntimeError, "Error", fn ->
     conn(:get, "/error_route")
     |> ExampleApp.call([])
   end)
  end

  test "builds request data" do
    conn = conn(:get, "/error_route?key=value")
    |> put_req_cookie("cookie_key", "cookie_value")
    |> put_req_header("accept-language", "en-US")

    request_data = Sentry.Plug.build_request_interface_data(conn, [])

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
      "cc" => "4242424242424242" })
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

    request_data = Sentry.Plug.build_request_interface_data(conn, scrubber: scrubber)
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
end
