defmodule Sentry.Envelope do
  @moduledoc false

  alias Sentry.{Config, Event, Transaction, Util}

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
  Adds a transaction to the envelope.
  """
  @spec add_transaction(t(), Transaction.t()) :: t()
  def add_transaction(envelope, %{event_id: event_id} = transaction) do
    envelope
    |> Map.put(:event_id, event_id)
    |> Map.update!(:items, fn items ->
      items ++ [transaction]
    end)
  end

  @doc """
  Encodes the envelope into it's binary representation.
  """
  @spec to_binary(t()) :: {:ok, String.t()} | {:error, any()}
  def to_binary(envelope) do
    buffer = case envelope.event_id do
        nil -> "{{}}\n"
        event_id -> "{\"event_id\":\"#{event_id}\"}\n"
      end

    json_library = Config.json_library()

    # write each item
    Enum.reduce_while(envelope.items, {:ok, buffer}, fn (item, {:ok, acc}) ->
      # encode to a temporary buffer to get the length
      result =
        case item do
          %Event{} ->
            item
            |> Sentry.Client.render_event()
            |> json_library.encode()

          _ -> json_library.encode(item)
        end

      case result do
        {:ok, json_item} ->
          length = byte_size(json_item)

          type_name = item_type_name(item)

          {:cont, {:ok, acc
            <> "{\"type\":\"#{type_name}\",\"length\":#{length}}\n"
            <> json_item
            <> "\n"}}
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
    json_library = Config.json_library()

    case String.split(binary, "\n") do
      [headers | items] ->
        {:ok, headers} = json_library.decode(headers)

        items =
          items
          |> Enum.chunk_every(2, 2, :discard)
          |> Enum.map(fn [k, v] -> {json_library.decode!(k), v} end)
          |> Enum.map(&decode_item!/1)

        {:ok, %__MODULE__{
          event_id: headers["event_id"] || nil,
          items: items
        }}

      _ -> {:error, :invalid_envelope}
    end
  end

  def from_binary!(binary) do
    {:ok, envelope} = from_binary(binary)
    envelope
  end

  # Returns the event in the envelope if one exists.
  @spec event(t()) :: Event.t() | nil
  def event(envelope) do
    envelope.items
    |> Enum.filter(fn item -> is_struct(item, Event) end)
    |> List.first()
  end

  defp item_type_name(%Event{}), do: "event"
  defp item_type_name(%Transaction{}), do: "transaction"
  defp item_type_name(unexpected), do: raise "unexpected item type '#{unexpected}' in Envelope.to_binary/1"

  defp decode_item!({%{"type" => "event"}, data}) do
    fields = Config.json_library().decode!(data)

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
        frames: fields["stacktrace"]["frames"],
      },
      tags: fields["tags"],
      timestamp: fields["timestamp"],
      user: fields["user"]
    }
  end
  defp decode_item!({%{"type" => type}, _data}), do: raise "unexpected item type '#{type}'"
  defp decode_item!({_, _data}), do: raise "Missing item type header"


end
