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

  @doc """
  Decodes the envelope from its binary representation.
  """
  @spec from_binary(String.t()) :: {:ok, t()} | {:error, :invalid_envelope}
  def from_binary(binary) when is_binary(binary) do
    json_library = Config.json_library()

    [raw_headers | raw_items] = String.split(binary, "\n")

    with {:ok, headers} <- json_library.decode(raw_headers),
         {:ok, items} <- decode_items(raw_items, json_library) do
      {:ok,
       %__MODULE__{
         event_id: headers["event_id"] || nil,
         items: items
       }}
    else
      {:error, _json_error} -> {:error, :invalid_envelope}
    end
  end

  #
  # Decoding
  #

  # Steps over the item pairs in the envelope body. The item header is decoded
  # first so it can be used to decode the item following it.
  defp decode_items(raw_items, json_library) do
    items =
      raw_items
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.map(fn [k, v] ->
        with {:ok, item_header} <- json_library.decode(k),
             {:ok, item} <- decode_item(item_header, v, json_library) do
          item
        else
          {:error, _reason} = error -> throw(error)
        end
      end)

    {:ok, items}
  catch
    {:error, reason} -> {:error, reason}
  end

  defp decode_item(%{"type" => "event"}, data, json_library) do
    result = json_library.decode(data)

    case result do
      {:ok, fields} ->
        {:ok,
         %Event{
           breadcrumbs: fields["breadcrumbs"],
           culprit: fields["culprit"],
           environment: fields["environment"],
           event_id: fields["event_id"],
           source: fields["event_source"],
           exception: List.wrap(fields["exception"]),
           extra: fields["extra"],
           fingerprint: fields["fingerprint"],
           level: fields["level"],
           message: fields["message"],
           modules: fields["modules"],
           original_exception: fields["original_exception"],
           platform: fields["platform"],
           release: fields["release"],
           request: fields["request"],
           server_name: fields["server_name"],
           tags: fields["tags"],
           timestamp: fields["timestamp"],
           user: fields["user"]
         }}

      {:error, e} ->
        {:error, "Failed to decode event item: #{e}"}
    end
  end

  defp decode_item(%{"type" => type}, _data, _json_library),
    do: {:error, "unexpected item type '#{type}'"}

  defp decode_item(_, _data, _json_library), do: {:error, "Missing item type header"}
end
