defmodule Sentry.PlugTest do
  use ExUnit.Case, async: true
  use Plug.Test

  defmodule ExampleApp do
    use Plug.Router
    use Plug.ErrorHandler
    use Sentry.Plug

    plug :match
    plug :dispatch

    get "/error_route" do
      _ = conn
      raise RuntimeError, "Error"
    end
  end

  test "exception re-raises" do
   assert_raise(RuntimeError, "Error", fn ->
      conn(:get, "/error_route")
      |> ExampleApp.call([])
    end)
  end

  test "builds request data" do
    conn = conn(:get, "/error_route?key=value")
    |> put_req_cookie("cookie_key", "cookie_value")
    |> put_req_header("accept-language", "en-US")

    request_data = Sentry.Plug.build_request_interface_data(conn)

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
end
