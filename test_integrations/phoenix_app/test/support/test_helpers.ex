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

  # Bypass envelope helpers — delegated to Sentry.Test

  defdelegate decode_envelope!(binary), to: Sentry.Test
  defdelegate extract_events(envelope_items_list), to: Sentry.Test
  defdelegate extract_transactions(envelope_items_list), to: Sentry.Test
  defdelegate extract_log_items(envelope_items_list), to: Sentry.Test

  def setup_bypass_envelope_collector(bypass, opts \\ []),
    do: Sentry.Test.setup_bypass_envelope_collector(bypass, opts)

  def collect_envelopes(ref, expected_count, opts \\ []),
    do: Sentry.Test.collect_envelopes(ref, expected_count, opts)
end
