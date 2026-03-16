defmodule Sentry.Integrations.Phoenix.MetricsTest do
  use PhoenixAppWeb.ConnCase, async: false

  import Sentry.TestHelpers

  setup do
    bypass = Bypass.open()
    test_pid = self()
    ref = make_ref()

    Bypass.expect(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {ref, body})
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    put_test_config(
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      enable_metrics: true,
      send_result: :sync
    )

    %{ref: ref, bypass: bypass}
  end

  describe "metrics from HTTP requests" do
    test "GET /metrics emits counter, gauge, and distribution metrics", %{conn: conn, ref: ref} do
      get(conn, ~p"/metrics")

      envelopes = collect_envelopes(ref, 4)
      metrics = extract_metrics(envelopes)

      types = Enum.map(metrics, & &1["type"]) |> Enum.uniq()
      assert "counter" in types
      assert "gauge" in types
      assert "distribution" in types
    end

    test "counter metric includes request attributes", %{conn: conn, ref: ref} do
      get(conn, ~p"/metrics")

      envelopes = collect_envelopes(ref, 4)
      metrics = extract_metrics(envelopes)

      counter = Enum.find(metrics, &(&1["name"] == "http.requests"))
      assert counter != nil
      assert counter["type"] == "counter"
      assert counter["value"] == 1
      assert counter["attributes"]["method"]["value"] == "GET"
      assert counter["attributes"]["path"]["value"] == "/metrics"
    end

    test "metrics inside traced spans have trace context", %{conn: conn, ref: ref} do
      get(conn, ~p"/metrics")

      envelopes = collect_envelopes(ref, 4)
      metrics = extract_metrics(envelopes)

      traced_metrics =
        Enum.filter(metrics, &(&1["name"] in ["users.count", "db.query_time"]))

      assert length(traced_metrics) == 2

      for metric <- traced_metrics do
        assert is_binary(metric["trace_id"]), "expected trace_id on #{metric["name"]}"
        assert String.length(metric["trace_id"]) == 32
        assert is_binary(metric["span_id"]), "expected span_id on #{metric["name"]}"
        assert String.length(metric["span_id"]) == 16
      end
    end

    test "traced metrics from same request share trace_id", %{conn: conn, ref: ref} do
      get(conn, ~p"/metrics")

      envelopes = collect_envelopes(ref, 4)
      metrics = extract_metrics(envelopes)

      traced_metrics = Enum.filter(metrics, &(&1["span_id"] != nil))
      assert length(traced_metrics) >= 2

      trace_ids = traced_metrics |> Enum.map(& &1["trace_id"]) |> Enum.uniq()
      assert length(trace_ids) == 1
    end

    test "separate requests produce different trace_ids", %{conn: conn, ref: ref} do
      get(conn, ~p"/metrics")
      envelopes1 = collect_envelopes(ref, 4)

      get(conn, ~p"/metrics")
      envelopes2 = collect_envelopes(ref, 4)

      metrics1 = extract_metrics(envelopes1)
      metrics2 = extract_metrics(envelopes2)

      traced1 = Enum.find(metrics1, &(&1["name"] == "users.count"))
      traced2 = Enum.find(metrics2, &(&1["name"] == "users.count"))

      assert traced1 != nil
      assert traced2 != nil
      assert traced1["trace_id"] != traced2["trace_id"]
    end
  end

  # Collect envelope bodies from Bypass
  defp collect_envelopes(ref, expected) do
    collect_envelopes(ref, expected, [])
  end

  defp collect_envelopes(_ref, 0, acc), do: Enum.reverse(acc)

  defp collect_envelopes(ref, remaining, acc) do
    receive do
      {^ref, body} -> collect_envelopes(ref, remaining - 1, [body | acc])
    after
      2000 -> Enum.reverse(acc)
    end
  end

  # Decode envelopes and extract the metric items
  defp extract_metrics(envelopes) do
    envelopes
    |> Enum.flat_map(&decode_envelope!/1)
    |> Enum.filter(fn {header, _payload} -> header["type"] == "trace_metric" end)
    |> Enum.flat_map(fn {_header, %{"items" => items}} -> items end)
  end
end
