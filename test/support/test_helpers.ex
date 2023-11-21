defmodule Sentry.TestHelpers do
  import ExUnit.Assertions

  alias Sentry.Envelope

  @spec decode_event_from_envelope!(binary()) :: Sentry.Event.t()
  def decode_event_from_envelope!(body) when is_binary(body) do
    {:ok, %Envelope{items: items}} = Envelope.from_binary(body)
    Enum.find(items, &is_struct(&1, Sentry.Event))
  end

  @spec put_test_config(keyword()) :: :ok
  def put_test_config(config) when is_list(config) do
    all_original_config = all_config()

    original_config =
      for {key, val} <- config do
        renamed_key =
          case key do
            :before_send_event -> :before_send
            other -> other
          end

        current_val = :persistent_term.get({:sentry_config, renamed_key}, :__not_set__)
        :persistent_term.put({:sentry_config, renamed_key}, val)
        {renamed_key, current_val}
      end

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(original_config, fn
        {key, :__not_set__} -> :persistent_term.erase({:sentry_config, key})
        {key, original_val} -> :persistent_term.put({:sentry_config, key}, original_val)
      end)

      assert all_original_config == all_config()
    end)
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
end
