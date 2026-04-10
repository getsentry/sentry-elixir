defmodule PhoenixAppWeb.TestConfigController do
  @moduledoc """
  Allows E2E tests to toggle Sentry configuration at runtime.
  Only intended for use when SENTRY_E2E_TEST_MODE=true.
  """

  use PhoenixAppWeb, :controller

  @allowed_keys ~w(strict_trace_continuation)a

  def update(conn, params) do
    Enum.each(@allowed_keys, fn key ->
      case Map.fetch(params, to_string(key)) do
        {:ok, value} when is_boolean(value) -> Sentry.put_config(key, value)
        _ -> :ok
      end
    end)

    json(conn, %{ok: true})
  end
end
