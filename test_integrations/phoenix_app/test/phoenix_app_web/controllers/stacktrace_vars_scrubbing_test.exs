defmodule Sentry.Integrations.Phoenix.StacktraceVarsScrubbingTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Sentry.TestHelpers

  @auth_token "Bearer super-secret-token-value-123"
  @cookie_value "session-id-deadbeef"

  setup do
    %{ref: ref} = Sentry.Test.setup_sentry(collect_envelopes: [type: "event"])
    %{ref: ref}
  end

  test "stacktrace frame vars do not leak conn auth headers or cookies",
       %{conn: conn, ref: ref} do
    conn =
      conn
      |> put_req_header("authorization", @auth_token)
      |> put_req_header("cookie", "session=#{@cookie_value}")

    assert_raise Phoenix.ActionClauseError, fn ->
      post(conn, ~p"/function-clause-error", %{})
    end

    [[{%{"type" => "event"}, event_payload}]] = collect_envelopes(ref, 1, timeout: 2000)

    frame_vars = frame_vars(event_payload)

    refute frame_vars =~ @auth_token,
           "auth token leaked into stacktrace frame vars: #{frame_vars}"

    refute frame_vars =~ @cookie_value,
           "session cookie leaked into stacktrace frame vars: #{frame_vars}"
  end

  test "user-provided body_scrubber on PlugContext is applied to conn in stacktrace args",
       %{conn: conn, ref: ref} do
    assert_raise Phoenix.ActionClauseError, fn ->
      post(conn, ~p"/function-clause-error", %{"password" => "secret-input"})
    end

    [[{%{"type" => "event"}, event_payload}]] = collect_envelopes(ref, 1, timeout: 2000)

    frame_vars = frame_vars(event_payload)

    assert frame_vars =~ "custom-scrub-applied",
           "user-provided body_scrubber marker missing from frame vars: #{frame_vars}"
  end

  test "default scrubbing redacts sensitive params when no custom body_scrubber is configured",
       %{conn: conn, ref: ref} do
    conn =
      conn
      |> put_req_header("authorization", @auth_token)
      |> put_req_header("cookie", "session=#{@cookie_value}")

    assert_raise Phoenix.ActionClauseError, fn ->
      post(
        conn,
        "/function-clause-error-default?password=qs-secret&keep_me=visible",
        %{"password" => "body-secret", "username" => "alice"}
      )
    end

    [[{%{"type" => "event"}, event_payload}]] = collect_envelopes(ref, 1, timeout: 2000)

    value = exception_value(event_payload)

    # Default key-based scrubbing redacts sensitive values wherever they appear:
    # body params, query params, query string, the auth header, and cookies.
    refute value =~ "body-secret", "body password leaked into exception value: #{value}"
    refute value =~ "qs-secret", "query password leaked into exception value: #{value}"
    refute value =~ @auth_token, "auth token leaked into exception value: #{value}"
    refute value =~ @cookie_value, "session cookie leaked into exception value: #{value}"

    # Non-sensitive data is preserved.
    assert value =~ "alice"
    assert value =~ "keep_me=visible"

    # The user-provided marker is NOT applied on this endpoint (default path).
    refute value =~ "custom-scrub-applied"
  end

  test "reduces conn.private to the allow-list (drops session data, keeps routing metadata)",
       %{conn: conn, ref: ref} do
    assert_raise Phoenix.ActionClauseError, fn ->
      post(conn, ~p"/function-clause-error-private", %{})
    end

    [[{%{"type" => "event"}, event_payload}]] = collect_envelopes(ref, 1, timeout: 2000)

    value = exception_value(event_payload)

    # The non-allow-listed :private key injected on the conn (and its session data)
    # is dropped from the captured exception.
    refute value =~ "plug_session", "non-allow-listed :private key leaked: #{value}"
    refute value =~ "secret-csrf-value", "session data leaked from conn.private: #{value}"

    # High-signal Phoenix routing metadata is retained.
    assert value =~ "phoenix_action", "expected routing metadata to be kept: #{value}"
    assert value =~ "phoenix_controller", "expected routing metadata to be kept: #{value}"
  end

  test "clears conn.assigns and req_cookies wholesale",
       %{conn: conn, ref: ref} do
    assert_raise Phoenix.ActionClauseError, fn ->
      post(conn, ~p"/function-clause-error-cleared", %{})
    end

    [[{%{"type" => "event"}, event_payload}]] = collect_envelopes(ref, 1, timeout: 2000)

    value = exception_value(event_payload)

    # assigns and req_cookies are cleared wholesale, so neither the injected
    # assign data nor the cookie value reaches Sentry.
    assert value =~ "assigns: %{}", "expected assigns to be cleared: #{value}"
    assert value =~ "req_cookies: %{}", "expected req_cookies to be cleared: #{value}"

    refute value =~ "secret-assigns-hash", "assigns data leaked: #{value}"
    refute value =~ "current_user", "assigns key leaked: #{value}"
    refute value =~ "secret-cookie-session", "req_cookies data leaked: #{value}"
  end

  test "scrubs args of a generic FunctionClauseError raised inside an action",
       %{conn: conn, ref: ref} do
    # This is a plain Elixir FunctionClauseError (not a Phoenix.ActionClauseError),
    # so it never goes through PlugCapture's ActionClauseError handling. Its args are
    # scrubbed by Sentry.Event via StacktraceScrubber when building the frame vars.
    assert_raise FunctionClauseError, fn ->
      post(conn, ~p"/generic-clause-error", %{})
    end

    [[{%{"type" => "event"}, event_payload}]] = collect_envelopes(ref, 1, timeout: 2000)

    frame_vars = frame_vars(event_payload)

    refute frame_vars =~ "raw-secret-password",
           "password leaked into stacktrace frame vars: #{frame_vars}"

    assert frame_vars =~ "alice",
           "expected non-sensitive arg data to be preserved: #{frame_vars}"
  end

  test "a non-Plug.Conn struct argument leaks its secrets into stacktrace frame vars",
       %{conn: conn, ref: ref} do
    # Realistic flow: a checkout action builds a %Billing.CreditCard{} value struct
    # and calls a billing function guarded by supported currencies. An unsupported
    # currency raises a generic FunctionClauseError, and the card struct rides in the
    # failing frame's args.
    #
    # Sentry scrubs frame args via Sentry.Scrubber.scrub/1, which returns any
    # non-Plug.Conn struct UNCHANGED — it never converts it to a map, so neither the
    # key-based nor the credit-card heuristics ever run on its fields. The PAN below
    # is the exact 16-digit shape Sentry's own credit-card heuristic redacts when it
    # appears as a *map* value; wrapped in a struct it bypasses scrubbing entirely.
    assert_raise FunctionClauseError, fn ->
      post(conn, ~p"/checkout", %{})
    end

    [[{%{"type" => "event"}, event_payload}]] = collect_envelopes(ref, 1, timeout: 2000)

    frame_vars = frame_vars(event_payload)

    # The struct was captured into the frame vars (non-sensitive field preserved),
    # so the refute below is a real leak, not an empty-frame false negative.
    assert frame_vars =~ "Alice Example",
           "expected the card struct to be captured into frame vars: #{frame_vars}"

    # The card number must not reach Sentry. This currently FAILS: scrub/1 leaves the
    # struct untouched, so the PAN is inspected verbatim into the frame var.
    refute frame_vars =~ "4242424242424242",
           "credit card number leaked into stacktrace frame vars: #{frame_vars}"
  end

  defp frame_vars(event_payload) do
    event_payload
    |> Map.fetch!("exception")
    |> hd()
    |> get_in(["stacktrace", "frames"])
    |> Enum.flat_map(fn frame -> Map.values(frame["vars"] || %{}) end)
    |> Enum.join("\n")
  end

  defp exception_value(event_payload) do
    event_payload
    |> Map.fetch!("exception")
    |> hd()
    |> Map.fetch!("value")
  end
end
