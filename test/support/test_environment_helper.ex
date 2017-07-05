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

  def modify_system_env(overrides) when is_map(overrides) do
    original_env = System.get_env()
    System.put_env(overrides)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each overrides, fn {key, _} ->
        if Map.has_key?(original_env, key) do
          System.put_env(key, Map.fetch!(original_env, key))
        else
          System.delete_env(key)
        end
      end
    end)
  end
end
