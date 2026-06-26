defmodule Sentry.Plug.LiveViewContextTest do
  use Sentry.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Sentry.Plug.LiveViewContext

  @session_key LiveViewContext.session_key()

  @trace "d4cda95b652f4a1592b449d5929fda1b-6e0c63257de34c92-1"
  @baggage "sentry-trace_id=d4cda95b652f4a1592b449d5929fda1b,sentry-public_key=abc"

  defp call_plug(conn) do
    conn
    |> init_test_session(%{})
    |> LiveViewContext.call(LiveViewContext.init([]))
  end

  describe "trace context fallback from request headers (no active OTel span)" do
    test "persists only trace-relevant headers, not sensitive ones" do
      conn =
        conn(:get, "/")
        |> put_req_header("sentry-trace", @trace)
        |> put_req_header("baggage", @baggage)
        |> put_req_header("authorization", "Bearer super-secret-token")
        |> put_req_header("cookie", "_app_session=topsecret")
        |> put_req_header("x-internal-proxy-secret", "10.0.0.1")
        |> call_plug()

      stored = get_session(conn, @session_key)

      assert stored["sentry-trace"] == @trace
      assert stored["baggage"] == @baggage

      refute Map.has_key?(stored, "authorization")
      refute Map.has_key?(stored, "cookie")
      refute Map.has_key?(stored, "x-internal-proxy-secret")
    end

    test "does not persist W3C trace headers, only Sentry's own" do
      conn =
        conn(:get, "/")
        |> put_req_header("sentry-trace", @trace)
        |> put_req_header(
          "traceparent",
          "00-#{String.duplicate("a", 32)}-#{String.duplicate("b", 16)}-01"
        )
        |> put_req_header("tracestate", "sentry=foo")
        |> call_plug()

      stored = get_session(conn, @session_key)

      assert stored["sentry-trace"] == @trace
      refute Map.has_key?(stored, "traceparent")
      refute Map.has_key?(stored, "tracestate")
    end

    test "stores nothing when there is no sentry-trace header" do
      conn =
        conn(:get, "/")
        |> put_req_header(
          "traceparent",
          "00-#{String.duplicate("a", 32)}-#{String.duplicate("b", 16)}-01"
        )
        |> put_req_header("authorization", "Bearer super-secret-token")
        |> put_req_header("cookie", "_app_session=topsecret")
        |> call_plug()

      assert get_session(conn, @session_key) == nil
    end
  end
end
