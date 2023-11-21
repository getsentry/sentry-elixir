defmodule Sentry.TestHelpers do
  import ExUnit.Assertions

  alias Sentry.Envelope

  @spec decode_event_from_envelope!(binary()) :: Sentry.Event.t()
  def decode_event_from_envelope!(body) when is_binary(body) do
    assert {:ok, %Envelope{items: items}} = Envelope.from_binary(body)
    Enum.find(items, &is_struct(&1, Sentry.Event))
  end

  @spec put_test_config(keyword()) :: :ok
  def put_test_config(config) when is_list(config) do
    original_config =
      for {key, _val} <- config do
        renamed_key =
          case key do
            :before_send_event -> :before_send
            other -> other
          end

        {renamed_key, :persistent_term.get({:sentry_config, renamed_key}, :__not_set__)}
      end

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(original_config, fn
        {key, :__not_set__} -> :persistent_term.erase({:sentry_config, key})
        {key, original_val} -> :persistent_term.put({:sentry_config, key}, original_val)
      end)
    end)

    :ok = Enum.each(config, fn {key, val} -> Sentry.put_config(key, val) end)
  end

  @spec set_mix_shell(module()) :: :ok
  def set_mix_shell(shell) do
    mix_shell = Mix.shell()
    ExUnit.Callbacks.on_exit(fn -> Mix.shell(mix_shell) end)
    Mix.shell(shell)
    :ok
  end
end
