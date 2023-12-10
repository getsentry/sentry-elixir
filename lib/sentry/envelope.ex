defmodule Sentry.Envelope do
  @moduledoc false
  # https://develop.sentry.dev/sdk/envelopes/

  alias Sentry.{Attachment, Config, Event, UUID}

  @type t() :: %__MODULE__{
          event_id: UUID.t(),
          items: [Event.t() | Attachment.t(), ...]
        }

  @enforce_keys [:event_id, :items]
  defstruct [:event_id, :items]

  @doc """
  Creates a new envelope containing the given event.

  Restrictions:

    * Envelopes can only have a single element of type "event"
    * Envelopes can have as many elements of type "attachment" as you want

  """
  @spec new([Event.t() | Attachment.t(), ...]) :: t()
  def new(items) when is_list(items) and items != [] do
    %Event{event_id: event_id} =
      case Enum.filter(items, &is_struct(&1, Event)) do
        [event] -> event
        [] -> raise ArgumentError, "cannot construct an envelope without an event"
        _other -> raise ArgumentError, "cannot construct an envelope with multiple events"
      end

    %__MODULE__{
      event_id: event_id,
      items: items
    }
  end

  @doc """
  Encodes the envelope into its binary representation.

  For now, we support only envelopes with a single event and any number of attachments
  in them.
  """
  @spec to_binary(t()) :: {:ok, binary()} | {:error, any()}
  def to_binary(%__MODULE__{} = envelope) do
    json_library = Config.json_library()

    headers_iodata =
      case envelope.event_id do
        nil -> "{{}}\n"
        event_id -> ~s({"event_id":"#{event_id}"}\n)
      end

    items_iodata = Enum.map(envelope.items, &item_to_binary(json_library, &1))

    {:ok, IO.iodata_to_binary([headers_iodata, items_iodata])}
  catch
    {:error, _reason} = error -> error
  end

  defp item_to_binary(json_library, %Event{} = event) do
    case event |> Sentry.Client.render_event() |> json_library.encode() do
      {:ok, encoded_event} ->
        header = ~s({"type": "event", "length": #{byte_size(encoded_event)}})
        [header, ?\n, encoded_event, ?\n]

      {:error, _reason} = error ->
        throw(error)
    end
  end

  defp item_to_binary(json_library, %Attachment{} = attachment) do
    header = %{"type" => "attachment", "length" => byte_size(attachment.data)}

    header =
      for {key, value} <- Map.take(attachment, [:filename, :content_type, :attachment_type]),
          not is_nil(value),
          into: header,
          do: {Atom.to_string(key), value}

    {:ok, header_iodata} = json_library.encode(header)

    [header_iodata, ?\n, attachment.data, ?\n]
  end
end
