defmodule Sentry.Envelope do
  @moduledoc false
  # https://develop.sentry.dev/sdk/envelopes/

  alias Sentry.{Config, Event, UUID}

  @type t() :: %__MODULE__{
          event_id: UUID.t(),
          items: [Event.t(), ...]
        }

  @enforce_keys [:event_id, :items]
  defstruct [:event_id, :items]

  @doc """
  Creates a new envelope containing the given event.

  Envelopes can only have a single element of type "event", so that's why we
  restrict on a single-element list.
  """
  @spec new([Event.t(), ...]) :: t()
  def new([%Event{event_id: event_id}] = events) do
    %__MODULE__{
      event_id: event_id,
      items: events
    }
  end

  @doc """
  Encodes the envelope into its binary representation.

  For now, we support only envelopes with a single event in them.
  """
  @spec to_binary(t()) :: {:ok, binary()} | {:error, any()}
  def to_binary(%__MODULE__{items: [%Event{} = event]} = envelope) do
    json_library = Config.json_library()

    headers_iodata =
      case envelope.event_id do
        nil -> "{{}}\n"
        event_id -> ~s({"event_id":"#{event_id}"}\n)
      end

    case event |> Sentry.Client.render_event() |> json_library.encode() do
      {:ok, encoded_event} ->
        body = [
          headers_iodata,
          ~s({"type": "event", "length": #{byte_size(encoded_event)}}\n),
          encoded_event,
          ?\n
        ]

        {:ok, IO.iodata_to_binary(body)}

      {:error, _reason} = error ->
        error
    end
  end
end
