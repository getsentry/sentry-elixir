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

  defp decode_envelope_items(items) do
    items
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [header, item] -> [{decode!(header), decode!(item)}]

      [""] -> []
    end)
  end
end
