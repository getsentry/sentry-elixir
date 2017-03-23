defmodule Sentry.PreEventSendFunctionTest do
  def pre_event_send_function(event) do
      metadata = Enum.into(Logger.metadata, %{})
      %{event | extra: Map.merge(event.extra, metadata)}
  end
end
