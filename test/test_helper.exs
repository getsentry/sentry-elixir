defmodule TestHelpers do
  import ExUnit.Assertions

  alias Sentry.Envelope

  def decode_event_from_envelope!(body) when is_binary(body) do
    assert {:ok, %Envelope{items: items}} = Envelope.from_binary(body)
    Enum.find(items, &is_struct(&1, Sentry.Event))
  end
end

Code.compile_file("test/support/example_plug_application.ex")
Code.require_file("test/support/test_environment_helper.exs")
Code.require_file("test/support/test_before_send_event.exs")
Code.require_file("test/support/test_filter.exs")
Code.require_file("test/support/test_gen_server.exs")
Code.require_file("test/support/test_error_view.exs")

Mox.defmock(Sentry.HTTPClientMock, for: Sentry.HTTPClient)
Mox.defmock(Sentry.TransportSenderMock, for: Sentry.Transport.Sender.Behaviour)

ExUnit.start(assert_receive_timeout: 500)

Application.ensure_all_started(:bypass)
Application.ensure_all_started(:telemetry)
