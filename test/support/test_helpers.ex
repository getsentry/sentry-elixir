defmodule Sentry.TestHelpers do
  import ExUnit.Assertions

  alias Sentry.Envelope

  @spec decode_event_from_envelope!(binary()) :: Sentry.Event.t()
  def decode_event_from_envelope!(body) when is_binary(body) do
    {:ok, %Envelope{items: items}} = from_binary(body)
    Enum.find(items, &is_struct(&1, Sentry.Event))
  end

  @spec put_test_config(keyword()) :: :ok
  def put_test_config(config) when is_list(config) do
    all_original_config = all_config()

    original_config =
      for {key, val} <- config do
        renamed_key =
          case key do
            :before_send_event -> :before_send
            other -> other
          end

        current_val = :persistent_term.get({:sentry_config, renamed_key}, :__not_set__)
        Sentry.put_config(renamed_key, val)
        {renamed_key, current_val}
      end

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(original_config, fn
        {key, :__not_set__} -> :persistent_term.erase({:sentry_config, key})
        {key, original_val} -> :persistent_term.put({:sentry_config, key}, original_val)
      end)

      assert all_original_config == all_config()
    end)
  end

  @spec set_mix_shell(module()) :: :ok
  def set_mix_shell(shell) do
    mix_shell = Mix.shell()
    ExUnit.Callbacks.on_exit(fn -> Mix.shell(mix_shell) end)
    Mix.shell(shell)
    :ok
  end

  @spec all_config() :: keyword()
  def all_config do
    Enum.sort(for {{:sentry_config, key}, value} <- :persistent_term.get(), do: {key, value})
  end

  def from_binary(binary) when is_binary(binary) do
    json_library = Sentry.Config.json_library()

    [raw_headers | raw_items] = String.split(binary, "\n")

    with {:ok, headers} <- json_library.decode(raw_headers),
         {:ok, items} <- decode_items(raw_items, json_library) do
      {:ok,
       %Envelope{
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
         %Sentry.Event{
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
