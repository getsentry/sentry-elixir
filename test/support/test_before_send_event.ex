defmodule Sentry.BeforeSendEventTest do
  def before_send_event(event) do
    metadata = Enum.into(Logger.metadata, %{})
    %{event | extra: Map.merge(event.extra, metadata)}
  end
end
