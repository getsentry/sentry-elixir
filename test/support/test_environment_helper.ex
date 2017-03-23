defmodule Sentry.TestEnvironmentHelper do
  def modify_env(app, overrides) do
    original_env = Application.get_all_env(app)
    Enum.each(overrides, fn {key, value} -> Application.put_env(app, key, value) end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each overrides, fn {key, _} ->
        if Keyword.has_key?(original_env, key) do
          Application.put_env(app, key, Keyword.fetch!(original_env, key))
        else
          Application.delete_env(app, key)
        end
      end
    end)
  end
end
