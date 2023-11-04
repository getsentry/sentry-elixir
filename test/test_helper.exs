defmodule TestHelpers do
  import ExUnit.Assertions

  alias Sentry.Envelope

  def decode_event_from_envelope!(body) when is_binary(body) do
    assert {:ok, %Envelope{items: items}} = Envelope.from_binary(body)
    Enum.find(items, &is_struct(&1, Sentry.Event))
  end
end

ExUnit.start(assert_receive_timeout: 500)

# Start :sentry and stop it right away, so that we can start/stop it in tests
# and test configuration. However, we want all dependent apps to be started, which
# is why we do this here.
{:ok, _} = Application.ensure_all_started(:sentry)
ExUnit.CaptureLog.capture_log(fn -> Application.stop(:sentry) end)
