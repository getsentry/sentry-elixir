defmodule Sentry.PlugContextTest do
  use ExUnit.Case
  use Plug.Test

  def body_scrubber(conn) do
    Map.take(conn.params, ["foo"])
  end

  def header_scrubber(conn) do
    Enum.into(conn.req_headers, %{})
    |> Map.take(["x-not-secret-header"])
  end

  def cookie_scrubber(conn) do
    Enum.into(conn.cookies, %{})
    |> Map.take(["not-secret"])
  end

  defp add_x_forwarded_for(conn, ip_str) do
    %{conn | req_headers: [{"x-forwarded-for", ip_str} | conn.req_headers]}
  end

  test "sets request context" do
    Sentry.PlugContext.call(conn(:get, "/test?hello=world"), [])

    assert %{
             request: %{
               url: "http://www.example.com/test?hello=world",
               method: "GET",
               query_string: "hello=world",
               data: %{
                 "hello" => "world"
               },
               env: %{
                 "REMOTE_ADDR" => "127.0.0.1",
                 "REMOTE_PORT" => _,
                 "REQUEST_ID" => _,
                 "SERVER_NAME" => "www.example.com",
                 "SERVER_PORT" => 80
               }
             }
           } = Sentry.Context.get_all()
  end

  test "sets request context with real client ip if request is forwarded" do
    Sentry.PlugContext.call(
      conn(:get, "/test?hello=world") |> add_x_forwarded_for("10.0.0.1"),
      []
    )

    assert %{
             request: %{
               url: "http://www.example.com/test?hello=world",
               method: "GET",
               query_string: "hello=world",
               data: %{
                 "hello" => "world"
               },
               env: %{
                 "REMOTE_ADDR" => "10.0.0.1",
                 "REMOTE_PORT" => _,
                 "REQUEST_ID" => _,
                 "SERVER_NAME" => "www.example.com",
                 "SERVER_PORT" => 80
               }
             }
           } = Sentry.Context.get_all()
  end

  test "allows configuring body scrubber" do
    Sentry.PlugContext.call(conn(:get, "/test?hello=world&foo=bar"),
      body_scrubber: {__MODULE__, :body_scrubber}
    )

    assert %{
             "foo" => "bar"
           } == Sentry.Context.get_all().request.data
  end

  test "allows configuring header scrubber" do
    conn(:get, "/test?hello=world&foo=bar")
    |> put_req_header("x-not-secret-header", "not secrets")
    |> put_req_header("x-secret-header", "secrets")
    |> Sentry.PlugContext.call(header_scrubber: {__MODULE__, :header_scrubber})

    assert %{"x-not-secret-header" => "not secrets"} == Sentry.Context.get_all().request.headers
  end

  test "allows configuring cookie scrubber" do
    conn(:get, "/test?hello=world&foo=bar")
    |> put_req_header("cookie", "secret=secret;not-secret=not-secret")
    |> Sentry.PlugContext.call(cookie_scrubber: {__MODULE__, :cookie_scrubber})

    assert %{"not-secret" => "not-secret"} == Sentry.Context.get_all().request.cookies
  end

  test "allows configuring request id header" do
    conn(:get, "/test?hello=world&foo=bar")
    |> put_resp_header("my-request-id", "abc123")
    |> Sentry.PlugContext.call(request_id_header: "my-request-id")

    assert %{"REQUEST_ID" => "abc123"} = Sentry.Context.get_all().request.env
  end

  test "default data scrubbing" do
    conn(:post, "/error_route", %{
      "secret" => "world",
      "password" => "test",
      "passwd" => "4242424242424242",
      "credit_card" => "4197 7215 7810 8280",
      "count" => 334,
      "cc" => "4197-7215-7810-8280",
      "another_cc" => "4197721578108280",
      "user" => %{"password" => "mypassword"},
      "payments" => [
        %{"yet_another_cc" => "4197-7215-7810-8280"}
      ]
    })
    |> put_req_cookie("secret", "secretvalue")
    |> put_req_cookie("regular", "value")
    |> put_req_header("authorization", "secrets")
    |> put_req_header("authentication", "secrets")
    |> put_req_header("content-type", "application/json")
    |> Sentry.PlugContext.call([])

    request_context = Sentry.Context.get_all().request

    assert request_context.data == %{
             "another_cc" => "*********",
             "cc" => "*********",
             "count" => 334,
             "credit_card" => "*********",
             "passwd" => "*********",
             "password" => "*********",
             "secret" => "*********",
             "user" => %{"password" => "*********"},
             "payments" => [
               %{"yet_another_cc" => "*********"}
             ]
           }
  end

  test "handles data scrubbing with file upload" do
    upload = %Plug.Upload{path: "test/fixtures/my_image.png", filename: "my_image.png"}

    conn(:post, "/error_route", %{"image" => upload, "password" => "my_password"})
    |> Sentry.PlugContext.call([])

    assert Sentry.Context.get_all().request.data == %{
             "password" => "*********",
             "image" => %{
               content_type: nil,
               filename: "my_image.png",
               path: "test/fixtures/my_image.png"
             }
           }
  end
end
