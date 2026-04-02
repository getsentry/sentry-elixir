defmodule Sentry.TestHelpers do
  import ExUnit.Assertions

  @spec decode!(String.t()) :: term()
  def decode!(binary) do
    assert {:ok, data} = Sentry.JSON.decode(binary, Sentry.Config.json_library())
    data
  end

  @spec decode!(term()) :: String.t()
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

  @spec decode_envelope!(binary()) :: [{header :: map(), item :: map()}]
  def decode_envelope!(binary) do
    [id_line | rest] = String.split(binary, "\n")
    %{"event_id" => _} = decode!(id_line)
    decode_envelope_items(rest)
  end

  @spec setup_bypass(keyword()) :: %{bypass: Bypass.t()}
  def setup_bypass(extra_config \\ []) do
    bypass = Bypass.open()

    # Stub all envelope requests by default so tests that don't explicitly
    # collect envelopes won't fail from background OTel span sends.
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

  @spec extract_events([[{map(), map()}]]) :: [map()]
  def extract_events(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "event"}, payload} <- items,
        do: payload
  end

  @spec extract_transactions([[{map(), map()}]]) :: [map()]
  def extract_transactions(envelope_items_list) do
    for items <- envelope_items_list,
        {%{"type" => "transaction"}, payload} <- items,
        do: payload
  end

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
