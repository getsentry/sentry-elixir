defmodule Sentry.Logger do
  use GenEvent

  @moduledoc """
  Setup the application environment in your config.

      config :sentry,
        dsn: "https://public:secret@app.getsentry.com/1"
        tags: %{
          env: "production"
        }

  Install the Logger backend.

      config :logger, backends: [:console, Sentry.Logger]
  """

  @type parsed_dsn :: {String.t, String.t, Integer.t}

  ## Server

  def handle_call({:configure, _options}, state) do
    {:ok, :ok, state}
  end

  def handle_event({:error, gl, {Logger, msg, _ts, _md}}, state) when node(gl) == node() do
    Sentry.capture_exception(msg)
    {:ok, state}
  end

  def handle_event(_data, state) do
    {:ok, state}
  end
end
