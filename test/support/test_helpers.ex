defmodule Sentry.TestHelpers do
  import ExUnit.Assertions

  alias Sentry.Envelope

  @spec decode_event_from_envelope!(binary()) :: Sentry.Event.t()
  def decode_event_from_envelope!(body) when is_binary(body) do
    assert {:ok, %Envelope{items: items}} = Envelope.from_binary(body)
    Enum.find(items, &is_struct(&1, Sentry.Event))
  end

  @spec modify_app_env(keyword()) :: :ok
  def modify_app_env(overrides) when is_list(overrides) do
    original_env = Application.get_all_env(:sentry)
    Enum.each(overrides, fn {key, value} -> Application.put_env(:sentry, key, value) end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(overrides, fn {key, _} ->
        if Keyword.has_key?(original_env, key) do
          Application.put_env(:sentry, key, Keyword.fetch!(original_env, key))
        else
          Application.delete_env(:sentry, key)
        end
      end)

      restart_app!()
    end)

    restart_app!()
  end

  @spec restart_app!() :: :ok
  def restart_app! do
    for {{:sentry_config, _} = key, _val} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    ExUnit.CaptureLog.capture_log(fn -> Application.stop(:sentry) end)
    assert {:ok, _} = Application.ensure_all_started(:sentry)
    :ok
  end
end
