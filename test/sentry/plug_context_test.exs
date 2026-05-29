defmodule Sentry.PlugContextTest do
  use Sentry.Case, async: false
  import Plug.Conn
  import Plug.Test

  setup do
    %{conn: conn(:get, "/test?hello=world")}
  end

  def body_scrubber(conn) do
    Map.take(conn.params, ["foo"])
  end

  def header_scrubber(conn) do
    conn.req_headers |> Map.new() |> Map.take(["x-not-secret-header"])
  end

  def cookie_scrubber(conn) do
    conn.cookies |> Map.new() |> Map.take(["not-secret"])
  end

  def url_scrubber(conn) do
    conn |> Plug.Conn.request_url() |> String.replace(~r/secret-token\/\w+/, "secret-token/****")
  end

  def remote_address_reader(conn) do
    case get_req_header(conn, "cf-connecting-ip") do
      [remote_ip | _] -> remote_ip
      _ -> conn.remote_ip
    end
  end

  test "sets request context", %{conn: conn} do
    call(conn, [])

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

  test "sets request context with real client ip if request is forwarded", %{conn: conn} do
    conn
    |> put_req_header("x-forwarded-for", "10.0.0.1")
    |> call([])

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

  test "allows configuring request address reader", %{conn: conn} do
    conn
    |> put_req_header("cf-connecting-ip", "10.0.0.2")
    |> call(remote_address_reader: {__MODULE__, :remote_address_reader})

    assert %{"REMOTE_ADDR" => "10.0.0.2"} = Sentry.Context.get_all().request.env
  end

  test "allows configuring body scrubber" do
    conn = conn(:get, "/test?hello=world&foo=bar")
    call(conn, body_scrubber: {__MODULE__, :body_scrubber})

    assert %{
             "foo" => "bar"
           } == Sentry.Context.get_all().request.data
  end

  test "allows configuring header scrubber", %{conn: conn} do
    conn
    |> put_req_header("x-not-secret-header", "not secrets")
    |> put_req_header("x-secret-header", "secrets")
    |> call(header_scrubber: {__MODULE__, :header_scrubber})

    assert %{"x-not-secret-header" => "not secrets"} == Sentry.Context.get_all().request.headers
  end

  test "allows configuring cookie scrubber", %{conn: conn} do
    conn
    |> put_req_header("cookie", "secret=secret;not-secret=not-secret")
    |> call(cookie_scrubber: {__MODULE__, :cookie_scrubber})

    assert %{"not-secret" => "not-secret"} == Sentry.Context.get_all().request.cookies
  end

  test "does not scrub the URL by default" do
    conn = conn(:get, "/test?password=hunter2")
    call(conn, [])

    assert "http://www.example.com/test?password=hunter2" ==
             Sentry.Context.get_all().request.url
  end

  test "allows configuring URL scrubber" do
    conn = conn(:get, "/secret-token/secret")
    call(conn, url_scrubber: {__MODULE__, :url_scrubber})

    assert "http://www.example.com/secret-token/****" == Sentry.Context.get_all().request.url
  end

  test "url_scrubber: nil falls back to the request URL unchanged" do
    conn = conn(:get, "/test?password=hunter2")
    call(conn, url_scrubber: nil)

    assert "http://www.example.com/test?password=hunter2" ==
             Sentry.Context.get_all().request.url
  end

  test "allows configuring request id header", %{conn: conn} do
    conn
    |> put_resp_header("my-request-id", "abc123")
    |> call(request_id_header: "my-request-id")

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
    |> call([])

    request_context = Sentry.Context.get_all().request

    assert request_context.headers == %{"content-type" => "application/json"}
    assert request_context.cookies == %{}

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

    conn = conn(:post, "/error_route", %{"image" => upload, "password" => "my_password"})
    call(conn, [])

    assert Sentry.Context.get_all().request.data == %{
             "password" => "*********",
             "image" => %{
               content_type: nil,
               filename: "my_image.png",
               path: "test/fixtures/my_image.png"
             }
           }
  end

  describe "scrubber registration" do
    test "registers a conn scrubber accessible via Sentry.Scrubber.scrub/1", %{conn: conn} do
      call(conn, [])

      scrubbed =
        Sentry.Scrubber.scrub(%Plug.Conn{
          cookies: %{"session" => "secret"},
          req_headers: [{"authorization", "Bearer x"}, {"x-keep", "yes"}],
          params: %{"password" => "hunter2", "ok" => "fine"}
        })

      assert scrubbed.cookies == %{}
      assert scrubbed.req_headers == [{"x-keep", "yes"}]
      assert scrubbed.params == %{"password" => "*********", "ok" => "fine"}
    end

    test "honors a custom body_scrubber when scrub/1 is called downstream",
         %{conn: conn} do
      call(conn, body_scrubber: {__MODULE__, :body_scrubber})

      scrubbed =
        Sentry.Scrubber.scrub(%Plug.Conn{
          params: %{"foo" => "kept", "bar" => "dropped"}
        })

      assert scrubbed.params == %{"foo" => "kept"}
    end
  end

  defp call(conn, opts) do
    Plug.run(conn, [{Sentry.PlugContext, opts}])
  end
end
