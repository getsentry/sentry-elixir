defmodule Sentry.TestEnvironmentHelper do
  import ExUnit.Assertions

  def modify_env(app, overrides) do
    original_env = Application.get_all_env(app)
    Enum.each(overrides, fn {key, value} -> Application.put_env(app, key, value) end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(overrides, fn {key, _} ->
        if Keyword.has_key?(original_env, key) do
          Application.put_env(app, key, Keyword.fetch!(original_env, key))
        else
          Application.delete_env(app, key)
        end
      end)

      restart_app()
    end)

    restart_app()
  end

  def delete_env(app, key) do
    original_env = Application.fetch_env(app, key)
    Application.delete_env(app, key)

    ExUnit.Callbacks.on_exit(fn ->
      case original_env do
        {:ok, val} -> Application.put_env(app, key, val)
        :error -> :ok
      end

      restart_app()
    end)

    restart_app()
  end

  def modify_system_env(overrides) when is_map(overrides) do
    original_env = System.get_env()
    System.put_env(overrides)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(overrides, fn {key, _} ->
        if Map.has_key?(original_env, key) do
          System.put_env(key, Map.fetch!(original_env, key))
        else
          System.delete_env(key)
        end
      end)

      restart_app()
    end)

    restart_app()
  end

  def delete_system_env(variable) do
    original_env = System.fetch_env(variable)

    System.delete_env(variable)

    ExUnit.Callbacks.on_exit(fn ->
      case original_env do
        {:ok, val} -> System.put_env(variable, val)
        :error -> :ok
      end

      restart_app()
    end)

    restart_app()
  end

  defp restart_app do
    for {{:sentry_config, _} = key, _val} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    ExUnit.CaptureLog.capture_log(fn -> Application.stop(:sentry) end)
    assert {:ok, _} = Application.ensure_all_started(:sentry)
  end
end
