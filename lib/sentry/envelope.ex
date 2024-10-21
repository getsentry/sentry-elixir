defmodule Sentry.Envelope do
  @moduledoc false
  # https://develop.sentry.dev/sdk/envelopes/

  alias Sentry.{Attachment, CheckIn, ClientReport, Config, Event, UUID}

  @type t() :: %__MODULE__{
          event_id: UUID.t(),
          items: [Event.t() | Attachment.t() | CheckIn.t() | ClientReport.t(), ...]
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
      event_id: check_in.check_in_id,
      items: [check_in]
    }
  end

  @doc """
  Creates a new envelope containing the client report.
  """
  @doc since: "10.8.0"
  @spec from_client_report(ClientReport.t()) :: t()
  def from_client_report(%ClientReport{} = client_report) do
    %__MODULE__{
      event_id: UUID.uuid4_hex(),
      items: [client_report]
    }
  end

  @doc """
  Returns the "data category" of the envelope's contents (to be used in client reports and more).
  """
  @doc since: "10.8.0"
  @spec get_data_category(Attachment.t() | CheckIn.t() | ClientReport.t() | Event.t()) ::
          String.t()
  def get_data_category(%Attachment{}), do: "attachment"
  def get_data_category(%CheckIn{}), do: "monitor"
  def get_data_category(%ClientReport{}), do: "internal"
  def get_data_category(%Event{}), do: "error"

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
        header = ~s({"type":"event","length":#{byte_size(encoded_event)}})
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
        header = ~s({"type":"check_in","length":#{byte_size(encoded_check_in)}})
        [header, ?\n, encoded_check_in, ?\n]

      {:error, _reason} = error ->
        throw(error)
    end
  end

  defp item_to_binary(json_library, %ClientReport{} = client_report) do
    case client_report |> Map.from_struct() |> json_library.encode() do
      {:ok, encoded_client_report} ->
        header = ~s({"type":"client_report","length":#{byte_size(encoded_client_report)}})
        [header, ?\n, encoded_client_report, ?\n]

      {:error, _reason} = error ->
        throw(error)
    end
  end
end
