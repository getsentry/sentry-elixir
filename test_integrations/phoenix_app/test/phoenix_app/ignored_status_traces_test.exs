defmodule PhoenixApp.IgnoredStatusTracesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  @port 4102
  @base_url "http://localhost:#{@port}"

  setup do
    start_supervised!({Bandit, plug: PhoenixAppWeb.Endpoint, scheme: :http, port: @port})
    Sentry.Test.setup_sentry(collect_envelopes: true, traces_sample_rate: 1.0)
  end

  test "a request answered with an ignored status is not traced", %{ref: ref} do
    put_test_config(traces_ignore_http_status_codes: [410])

    assert request("/responses/410") == 410
    assert request("/responses/200") == 200

    assert traced_paths(ref) == ["/responses/200"]
  end

  test "a request answered with 404 is not traced by default", %{ref: ref} do
    assert request("/responses/404") == 404
    assert request("/responses/200") == 200

    assert traced_paths(ref) == ["/responses/200"]
  end

  test "a request answered with 404 is traced when no status is ignored", %{ref: ref} do
    put_test_config(traces_ignore_http_status_codes: [])

    assert request("/responses/404") == 404

    assert traced_paths(ref) == ["/responses/404"]
  end

  test "a request answered with a status inside an ignored range is not traced", %{ref: ref} do
    put_test_config(traces_ignore_http_status_codes: [500..599])

    assert request("/responses/503") == 503
    assert request("/responses/404") == 404

    assert traced_paths(ref) == ["/responses/404"]
  end

  test "work outliving a request answered with an ignored status is not traced", %{ref: ref} do
    put_test_config(traces_ignore_http_status_codes: [410])
    test_process = register_test_process()

    assert request("/responses/410?test_process=#{test_process}&upstream_status=200") == 410
    assert reported_transactions(ref) == []

    finish_upstream_call()

    assert reported_transactions(ref) == []
  end

  test "an outgoing call answered with an ignored status outliving its request is traced", %{
    ref: ref
  } do
    put_test_config(traces_ignore_http_status_codes: [410])
    test_process = register_test_process()

    assert request("/responses/200?test_process=#{test_process}&upstream_status=410") == 200
    assert traced_paths(ref) == ["/responses/200"]

    finish_upstream_call()

    assert [upstream_tx] = reported_transactions(ref)
    assert upstream_tx["transaction"] == "GET /upstream"
  end

  test "a request answered with an ignored status is discarded by an event processor", %{
    ref: ref,
    client_report_sender: sender
  } do
    put_test_config(traces_ignore_http_status_codes: [410])
    log_at_debug_level()

    log =
      capture_log([level: :debug], fn ->
        assert request("/responses/410") == 410
        assert reported_transactions(ref) == []
      end)

    assert log =~ ~r/\[debug\]\s+Discarding transaction .*response status 410/

    assert discarded_outcomes(sender, ref, "event_processor") == %{
             "transaction" => 1,
             "span" => 1
           }
  end

  defp log_at_debug_level do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  defp request(path) do
    {:ok, {{_version, status, _reason}, _headers, _body}} =
      :httpc.request(:get, {String.to_charlist(@base_url <> path), []}, [], [])

    status
  end

  defp register_test_process do
    name = :"ignored_status_traces_#{System.unique_integer([:positive])}"
    Process.register(self(), name)
    name
  end

  defp finish_upstream_call do
    assert_receive {:upstream_call, upstream_pid}, 1000
    send(upstream_pid, :finish_upstream_call)
    assert_receive :upstream_call_finished, 1000
  end

  defp reported_transactions(ref) do
    collect_sentry_transactions(ref, 100, timeout: 1000)
  end

  defp traced_paths(ref) do
    Enum.map(reported_transactions(ref), & &1["contexts"]["trace"]["data"]["url.path"])
  end

  defp discarded_outcomes(sender, ref, reason) do
    :ok = Sentry.ClientReport.Sender.flush(sender)

    for outcome <- await_client_report(ref)["discarded_events"],
        outcome["reason"] == reason,
        into: %{},
        do: {outcome["category"], outcome["quantity"]}
  end

  defp await_client_report(ref) do
    receive do
      {:bypass_envelope, ^ref, body} ->
        case decode_envelope!(body) do
          [{%{"type" => "client_report"}, client_report}] -> client_report
          _other -> await_client_report(ref)
        end
    after
      2000 -> flunk("no client report envelope received")
    end
  end
end
