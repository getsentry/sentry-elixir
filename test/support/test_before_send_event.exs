defmodule Sentry.BeforeSendEventTest do
  def before_send_event(event) do
    metadata = Map.new(Logger.metadata)
    %{event | extra: Map.merge(event.extra, metadata)}
  end
end
