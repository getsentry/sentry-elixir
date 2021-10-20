defmodule Sentry.Envelope do
  @moduledoc false

  alias Sentry.{Config, Event, Util}

  @type t :: %__MODULE__{
          event_id: String.t()
        }

  defstruct event_id: nil, items: []

  @doc """
  Creates a new empty envelope.
  """
  @spec new() :: t()
  def new() do
    %__MODULE__{
      event_id: Util.uuid4_hex(),
      items: []
    }
  end

  @doc """
  Adds an event to the envelope.
  """
  @spec add_event(t(), Event.t()) :: t()
  def add_event(envelope, %{event_id: event_id} = event) do
    envelope
    |> Map.put(:event_id, event_id)
    |> Map.update!(:items, fn items ->
      items ++ [event]
    end)
  end

  @doc """
  Encodes the envelope into it's binary representation.
  """
  @spec to_binary(t()) :: {:ok, String.t()} | {:error, any()}
  def to_binary(envelope) do
    buffer = encode_headers(envelope)

    # write each item
    Enum.reduce_while(envelope.items, {:ok, buffer}, fn item, {:ok, acc} ->
      # encode to a temporary buffer to get the length
      case encode_item(item) do
        {:ok, encoded_item} ->
          length = byte_size(encoded_item)
          type_name = item_type_name(item)

          {:cont,
           {:ok,
            acc <>
              "{\"type\":\"#{type_name}\",\"length\":#{length}}\n" <>
              encoded_item <>
              "\n"}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  Decodes the envelope from it's binary representation.
  """
  @spec from_binary(String.t()) :: {:ok, t()} | {:error, :invalid_envelope}
  def from_binary(binary) do
    with {:ok, {raw_headers, raw_items}} <- decode_lines(binary),
         {:ok, headers} <- decode_headers(raw_headers),
         {:ok, items} <- decode_items(raw_items) do
      {:ok,
       %__MODULE__{
         event_id: headers["event_id"] || nil,
         items: items
       }}
    else
      _e -> {:error, :invalid_envelope}
    end
  end

  @spec from_binary!(String.t()) :: t() | no_return()
  def from_binary!(binary) do
    {:ok, envelope} = from_binary(binary)
    envelope
  end

  # Returns the event in the envelope if one exists.
  @spec event(t()) :: Event.t() | nil
  def event(envelope) do
    envelope.items
    |> Enum.filter(fn item -> is_event?(item) end)
    |> List.first()
  end

  defp is_event?(event), do: match?(%{__struct__: Sentry.Event}, event)

  #
  # Encoding
  #

  defp item_type_name(%Event{}), do: "event"

  defp item_type_name(unexpected),
    do: raise("unexpected item type '#{unexpected}' in Envelope.to_binary/1")

  defp encode_headers(envelope) do
    case envelope.event_id do
      nil -> "{{}}\n"
      event_id -> "{\"event_id\":\"#{event_id}\"}\n"
    end
  end

  defp encode_item(%Event{} = event) do
    event
    |> Sentry.Client.render_event()
    |> Config.json_library().encode()
  end

  defp encode_item(item), do: item

  #
  # Decoding
  #

  # Steps over the item pairs in the envelope body. The item header is decoded
  # first so it can be used to decode the item following it.
  @spec decode_items([String.t()]) :: {:ok, [map()]} | {:error, any()}
  defp decode_items(raw_items) do
    item_pairs = Enum.chunk_every(raw_items, 2, 2, :discard)

    Enum.reduce_while(item_pairs, {:ok, []}, fn [k, v], {:ok, acc} ->
      with {:ok, item_header} <- Config.json_library().decode(k),
           {:ok, item} <- decode_item(item_header, v) do
        {:cont, {:ok, acc ++ [item]}}
      else
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
  end

  defp decode_item(%{"type" => "event"}, data) do
    result = Config.json_library().decode(data)

    case result do
      {:ok, fields} ->
        {:ok,
         %Sentry.Event{
           breadcrumbs: fields["breadcrumbs"],
           culprit: fields["culprit"],
           environment: fields["environment"],
           event_id: fields["event_id"],
           event_source: fields["event_source"],
           exception: fields["exception"],
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
           stacktrace: %{
             frames: fields["stacktrace"]["frames"]
           },
           tags: fields["tags"],
           timestamp: fields["timestamp"],
           user: fields["user"]
         }}

      {:error, e} ->
        {:error, "Failed to decode event item: #{e}"}
    end
  end

  defp decode_item(%{"type" => type}, _data), do: {:error, "unexpected item type '#{type}'"}
  defp decode_item(_, _data), do: {:error, "Missing item type header"}

  defp decode_lines(binary) do
    case String.split(binary, "\n") do
      [headers | items] -> {:ok, {headers, items}}
      _ -> {:error, :missing_header}
    end
  end

  defp decode_headers(raw_headers), do: Config.json_library().decode(raw_headers)
end
