defmodule Sentry.Logger do
  use GenEvent

  @moduledoc """
    Provides a `Logger` backend for Sentry. This will automatically
    submit Error level Logger events to Sentry.

    ### Configuration
    Simply add the following to your config:

        config :logger, backends: [:console, Sentry.Logger]
  """

  @doc """
    Default `GenEvent` event handler for logger.
  """
  def handle_event({:error, gl, {Logger, msg, _ts, metadata}}, state) when node(gl) == node() do
    unless Keyword.has_key?(metadata, :skip_sentry) do
      Sentry.capture_logger_message(msg)
    end

    {:ok, state}
  end

  def handle_event(_data, state) do
    {:ok, state}
  end
end
