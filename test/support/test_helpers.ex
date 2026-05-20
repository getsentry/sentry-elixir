defmodule Sentry.TestHelpers do
  import ExUnit.Assertions

  alias Sentry.Interfaces.Span
  alias Sentry.Transaction

  @spec decode!(String.t()) :: term()
  def decode!(binary) do
    assert {:ok, data} = Sentry.JSON.decode(binary, Sentry.Config.json_library())
    data
  end

  @spec encode!(term()) :: String.t()
  def encode!(data) do
    assert {:ok, binary} = Sentry.JSON.encode(data, Sentry.Config.json_library())
    binary
  end

  @spec put_test_config(keyword()) :: :ok
  def put_test_config(config) when is_list(config) do
    Sentry.Test.Config.put(config)
  end

  @spec set_mix_shell(module()) :: :ok
  def set_mix_shell(shell) do
    mix_shell = Mix.shell()
    ExUnit.Callbacks.on_exit(fn -> Mix.shell(mix_shell) end)
    Mix.shell(shell)
    :ok
  end

  @spec all_config() :: keyword()
  def all_config do
    Enum.sort(for {{:sentry_config, key}, value} <- :persistent_term.get(), do: {key, value})
  end

  def create_span(attrs \\ %{}) do
    Map.merge(
      %Span{
        trace_id: "trace-312",
        span_id: "span-123",
        start_timestamp: "2025-01-01T00:00:00Z",
        timestamp: "2025-01-02T02:03:00Z"
      },
      attrs
    )
  end

  def create_transaction(attrs \\ %{}) do
    Transaction.new(
      Map.merge(
        %{
          span_id: "parent-312",
          start_timestamp: "2025-01-01T00:00:00Z",
          timestamp: "2025-01-02T02:03:00Z",
          contexts: %{
            trace: %{
              trace_id: "trace-312",
              span_id: "parent-312"
            }
          },
          spans: [
            create_span(%{parent_span_id: "parent-312"})
          ]
        },
        attrs
      )
    )
  end

  @spec setup_bypass(keyword()) :: %{bypass: Bypass.t()}
  def setup_bypass(extra_config \\ []) do
    bypass = Bypass.open()

    # Stub all envelope requests by default so tests that don't explicitly
    # collect envelopes won't fail from background span sends.
    Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
      Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
    end)

    config =
      [
        dsn: "http://public:secret@localhost:#{bypass.port}/1",
        finch_request_opts: [receive_timeout: 2000]
      ]
      |> Keyword.merge(extra_config)

    put_test_config(config)
    %{bypass: bypass}
  end

  # Bypass envelope helpers — delegated to Sentry.Test

  defdelegate decode_envelope!(binary), to: Sentry.Test
  defdelegate extract_events(envelope_items_list), to: Sentry.Test
  defdelegate extract_transactions(envelope_items_list), to: Sentry.Test
  defdelegate extract_log_items(envelope_items_list), to: Sentry.Test
  defdelegate extract_check_ins(envelope_items_list), to: Sentry.Test
  defdelegate extract_metric_items(envelope_items_list), to: Sentry.Test
  defdelegate collect_sentry_events(ref, count), to: Sentry.Test
  defdelegate collect_sentry_events(ref, count, opts), to: Sentry.Test
  defdelegate collect_sentry_transactions(ref, count), to: Sentry.Test
  defdelegate collect_sentry_transactions(ref, count, opts), to: Sentry.Test
  defdelegate collect_sentry_logs(ref, count), to: Sentry.Test
  defdelegate collect_sentry_logs(ref, count, opts), to: Sentry.Test
  defdelegate collect_sentry_check_ins(ref, count), to: Sentry.Test
  defdelegate collect_sentry_check_ins(ref, count, opts), to: Sentry.Test
  defdelegate collect_sentry_metric_items(ref, count), to: Sentry.Test
  defdelegate collect_sentry_metric_items(ref, count, opts), to: Sentry.Test

  def setup_bypass_envelope_collector(bypass, opts \\ []),
    do: Sentry.Test.setup_bypass_envelope_collector(bypass, opts)

  def collect_envelopes(ref, expected_count, opts \\ []),
    do: Sentry.Test.collect_envelopes(ref, expected_count, opts)

  @doc """
  Polls `condition_fn` until it returns a truthy value or `timeout`
  (default 1000ms) elapses, using exponential backoff (1ms, doubling,
  capped at 50ms).

  Returns `true` when the condition became truthy, `false` on timeout.
  Use this to wait on asynchronous state (e.g. a GenServer processing a
  `:DOWN`, a buffer draining) instead of a fixed `Process.sleep/1`.
  """
  @spec wait_until((-> as_boolean(term())), timeout()) :: boolean()
  def wait_until(condition_fn, timeout \\ 1000) when is_function(condition_fn, 0) do
    end_time = System.monotonic_time(:millisecond) + timeout
    wait_until_loop(condition_fn, end_time, 1)
  end

  defp wait_until_loop(condition_fn, end_time, sleep_time) do
    cond do
      condition_fn.() ->
        true

      System.monotonic_time(:millisecond) >= end_time ->
        false

      true ->
        Process.sleep(sleep_time)
        wait_until_loop(condition_fn, end_time, min(sleep_time * 2, 50))
    end
  end
end
