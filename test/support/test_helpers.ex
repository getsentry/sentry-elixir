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
    # Store original values from both process dictionary and :persistent_term
    # We validate each key individually like Sentry.put_config/2 does
    original_config =
      for {key, val} <- config do
        renamed_key =
          case key do
            :before_send_event -> :before_send
            other -> other
          end

        # Validate this single key-value pair (this also transforms values like DSN strings)
        validated_config = Sentry.Config.validate!([{renamed_key, val}])
        validated_val = Keyword.fetch!(validated_config, renamed_key)

        # Store original values
        current_process_val = Process.get({:sentry_test_config, renamed_key}, :__not_set__)
        current_persistent_val = :persistent_term.get({:sentry_config, renamed_key}, :__not_set__)

        # Set in both locations:
        # - Process dictionary for process-local isolation
        # - :persistent_term so spawned processes (like sender pool workers) can see it
        Process.put({:sentry_test_config, renamed_key}, validated_val)
        :persistent_term.put({:sentry_config, renamed_key}, validated_val)

        {renamed_key, current_process_val, current_persistent_val}
      end

    # Register cleanup to restore original values in both locations
    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(original_config, fn
        {key, :__not_set__, :__not_set__} ->
          Process.delete({:sentry_test_config, key})
          :persistent_term.erase({:sentry_config, key})

        {key, :__not_set__, persistent_val} ->
          Process.delete({:sentry_test_config, key})
          :persistent_term.put({:sentry_config, key}, persistent_val)

        {key, process_val, :__not_set__} ->
          Process.put({:sentry_test_config, key}, process_val)
          :persistent_term.erase({:sentry_config, key})

        {key, process_val, persistent_val} ->
          Process.put({:sentry_test_config, key}, process_val)
          :persistent_term.put({:sentry_config, key}, persistent_val)
      end)
    end)

    :ok
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

  @spec decode_envelope!(binary()) :: [{header :: map(), item :: map()}]
  def decode_envelope!(binary) do
    [id_line | rest] = String.split(binary, "\n")
    %{"event_id" => _} = decode!(id_line)
    decode_envelope_items(rest)
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

  @doc """
  Opens a Bypass instance and configures the DSN to point to it.
  Returns a map with `:bypass` for use in test context.

  ## Options

    * Any extra config options to pass to `put_test_config/1`.

  ## Examples

      setup do
        setup_bypass()
      end

      setup do
        setup_bypass(dedup_events: false)
      end

  """
  @spec setup_bypass(keyword()) :: %{bypass: Bypass.t()}
  def setup_bypass(extra_config \\ []) do
    bypass = Bypass.open()

    # Stub all envelope requests by default so tests that don't explicitly
    # collect envelopes won't fail from background span sends.
    Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
      Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
    end)

    config =
      [dsn: "http://public:secret@localhost:#{bypass.port}/1", finch_request_opts: [receive_timeout: 2000]]
      |> Keyword.merge(extra_config)

    put_test_config(config)
    %{bypass: bypass}
  end

  @doc """
  Sets up a Bypass envelope collector that forwards envelope bodies
  to the test process as messages. Returns a reference for collecting results.

  Uses `Bypass.stub` (not `Bypass.expect`) to be resilient to stray requests
  from background processes (e.g., OpenTelemetry span processor) that may
  hit this Bypass due to concurrent persistent_term DSN writes in async tests.

  Use with `collect_envelopes/2` to retrieve the decoded envelopes.

  ## Options

    * `:type` - when set, only envelopes containing an item of this type
      (e.g., `"event"`, `"transaction"`, `"log"`) are forwarded to the test
      process. Envelopes not matching the type are silently dropped. This is
      useful in async tests where stray envelopes of other types may arrive
      from background processes.

  """
  @spec setup_bypass_envelope_collector(Bypass.t(), keyword()) :: reference()
  def setup_bypass_envelope_collector(bypass, opts \\ []) do
    test_pid = self()
    ref = make_ref()
    type_filter = Keyword.get(opts, :type)

    Bypass.stub(bypass, "POST", "/api/1/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if is_nil(type_filter) or body =~ ~s("type":"#{type_filter}") do
        send(test_pid, {:bypass_envelope, ref, body})
      end

      Plug.Conn.resp(conn, 200, ~s<{"id": "#{Sentry.UUID.uuid4_hex()}"}>)
    end)

    ref
  end

  @doc """
  Collects decoded envelopes sent to a Bypass collector.

  Returns a list of decoded envelope item lists. Each element is the result
  of `decode_envelope!/1` for one HTTP request.

  ## Options

    * `:timeout` - timeout in ms to wait for each envelope (default: 1000)

  """
  @spec collect_envelopes(reference(), pos_integer(), keyword()) :: [[{map(), map()}]]
  def collect_envelopes(ref, expected_count, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    do_collect_envelopes(ref, expected_count, [], timeout)
  end

  defp do_collect_envelopes(_ref, 0, acc, _timeout), do: Enum.reverse(acc)

  defp do_collect_envelopes(ref, remaining, acc, timeout) do
    receive do
      {:bypass_envelope, ^ref, body} ->
        items = decode_envelope!(body)
        do_collect_envelopes(ref, remaining - 1, [items | acc], timeout)
    after
      timeout ->
        Enum.reverse(acc)
    end
  end

  @doc """
  Extracts event payloads from decoded envelope item lists.
  """
  @spec extract_events([[{map(), map()}]]) :: [map()]
  def extract_events(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "event"}, payload} <- items,
        do: payload
  end

  @doc """
  Extracts transaction payloads from decoded envelope item lists.
  """
  @spec extract_transactions([[{map(), map()}]]) :: [map()]
  def extract_transactions(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "transaction"}, payload} <- items,
        do: payload
  end

  @doc """
  Extracts log item payloads from decoded envelope item lists.
  """
  @spec extract_log_items([[{map(), map()}]]) :: [map()]
  def extract_log_items(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "log"}, payload} <- items,
        do: payload
  end

  defp decode_envelope_items(items) do
    items
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [header, item] -> [{decode!(header), decode!(item)}]

      [""] -> []
    end)
  end
end
