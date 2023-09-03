defmodule TestHelpers do
  import ExUnit.Assertions

  alias Sentry.Envelope

  def decode_event_from_envelope!(body) when is_binary(body) do
    assert {:ok, %Envelope{items: items}} = Envelope.from_binary(body)
    Enum.find(items, &is_struct(&1, Sentry.Event))
  end
end

ExUnit.start(assert_receive_timeout: 500)
