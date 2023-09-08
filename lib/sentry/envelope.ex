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
  Creates a new envelope containing the given events.
  """
  @spec new([Event.t(), ...]) :: t()
  def new([%Event{event_id: event_id} | _rest] = events) do
    %__MODULE__{
      event_id: event_id,
      items: events
    }
  end

  @doc """
  Encodes the envelope into its binary representation.
  """
  @spec to_binary(t()) :: {:ok, binary()} | {:error, any()}
  def to_binary(%__MODULE__{} = envelope) do
    json_library = Config.json_library()

    encoded_items =
      Enum.map(envelope.items, fn item ->
        case encode_item(item, json_library) do
          {:ok, encoded_item} ->
            type =
              if is_struct(item, Event) do
                "event"
              else
                raise "unexpected item in envelope: #{inspect(item)}"
              end

            [
              ~s({"type": "#{type}", "length": #{byte_size(encoded_item)}}\n),
              encoded_item,
              ?\n
            ]

          {:error, _reason} = error ->
            throw(error)
        end
      end)

    {:ok, IO.iodata_to_binary([encode_headers(envelope) | encoded_items])}
  catch
    {:error, reason} -> {:error, reason}
  end

  @doc """
  Decodes the envelope from its binary representation.
  """
  @spec from_binary(String.t()) :: {:ok, t()} | {:error, reason}
        when reason: :invalid_envelope | :missing_header
  def from_binary(binary) when is_binary(binary) do
    json_library = Config.json_library()

    with {:ok, {raw_headers, raw_items}} <- decode_lines(binary),
         {:ok, headers} <- json_library.decode(raw_headers),
         {:ok, items} <- decode_items(raw_items, json_library) do
      {:ok,
       %__MODULE__{
         event_id: headers["event_id"] || nil,
         items: items
       }}
    else
      {:error, :missing_header} = error -> error
      {:error, _json_error} -> {:error, :invalid_envelope}
    end
  end

  #
  # Encoding
  #

  defp encode_headers(%__MODULE__{} = envelope) do
    case envelope.event_id do
      nil -> "{{}}\n"
      event_id -> ~s({"event_id":"#{event_id}"}\n)
    end
  end

  defp encode_item(%Event{} = event, json_library) do
    event
    |> Sentry.Client.render_event()
    |> json_library.encode()
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

  defp decode_lines(binary) do
    case String.split(binary, "\n") do
      [headers | items] -> {:ok, {headers, items}}
      _ -> {:error, :missing_header}
    end
  end
end
