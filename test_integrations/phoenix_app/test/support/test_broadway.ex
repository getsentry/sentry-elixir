defmodule PhoenixApp.TestBroadway do
  @moduledoc false

  use Broadway

  def start_link(_opts \\ []) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [module: {Broadway.DummyProducer, []}],
      processors: [default: [concurrency: 1]]
    )
  end

  @impl true
  def handle_message(_processor, %Broadway.Message{data: data} = message, _context) do
    case data do
      :capture ->
        Sentry.capture_message("from broadway", result: :sync)

      :raise ->
        raise "broadway boom"

      _ ->
        :ok
    end

    message
  end
end
