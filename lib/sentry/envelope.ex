defmodule Sentry.Envelope do
  @moduledoc false
  # https://develop.sentry.dev/sdk/envelopes/

  alias Sentry.{Attachment, CheckIn, Config, Event, UUID}

  @type t() :: %__MODULE__{
          event_id: UUID.t(),
          items: [Event.t() | Attachment.t() | CheckIn.t(), ...]
        }

  @enforce_keys [:event_id, :items]
  defstruct [:event_id, :items]

  @doc """
  Creates a new envelope containing the given event and all of its attachments.
  """
  @spec from_event(Event.t()) :: t()
  def from_event(%Event{event_id: event_id} = event) do
    %__MODULE__{
      event_id: event_id,
      items: [event] ++ event.attachments
    }
  end

  @doc """
  Creates a new envelope containing the given check-in.
  """
  @spec from_check_in(CheckIn.t()) :: t()
  def from_check_in(%CheckIn{} = check_in) do
    %__MODULE__{
      event_id: UUID.uuid4_hex(),
      items: [check_in]
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

  defp item_to_binary(json_library, %CheckIn{} = check_in) do
    case check_in |> CheckIn.to_map() |> json_library.encode() do
      {:ok, encoded_check_in} ->
        header = ~s({"type": "check_in", "length": #{byte_size(encoded_check_in)}})
        [header, ?\n, encoded_check_in, ?\n]

      {:error, _reason} = error ->
        throw(error)
    end
  end
end
