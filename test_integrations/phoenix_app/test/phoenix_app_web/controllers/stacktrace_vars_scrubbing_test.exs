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

  defp frame_vars(event_payload) do
    event_payload
    |> Map.fetch!("exception")
    |> hd()
    |> get_in(["stacktrace", "frames"])
    |> Enum.flat_map(fn frame -> Map.values(frame["vars"] || %{}) end)
    |> Enum.join("\n")
  end
end
