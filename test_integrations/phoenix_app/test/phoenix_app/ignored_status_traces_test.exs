defmodule PhoenixApp.IgnoredStatusTracesTest do
  use ExUnit.Case, async: false

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
end
