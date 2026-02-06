defmodule PhoenixApp.TestClient do
  @moduledoc """
  A test Sentry client that logs envelopes to a file for e2e test validation.
  """

  require Logger

  @behaviour Sentry.HTTPClient

  @impl true
  def post(_url, _headers, body) do
    log_envelope(body)

    # Return success response
    {:ok, 200, [], ~s({"id":"test-event-id"})}
  end

  defp log_envelope(body) when is_binary(body) do
    log_file = Path.join([File.cwd!(), "tmp", "sentry_debug_events.log"])

    # Ensure the tmp directory exists
    log_dir = Path.dirname(log_file)
    File.mkdir_p!(log_dir)

    # Parse the envelope binary to extract events and headers
    case parse_envelope(body) do
      {:ok, envelope_data} ->
        # Write the envelope data as JSON
        json = Jason.encode!(envelope_data)
        File.write!(log_file, json <> "\n", [:append])

      {:error, reason} ->
        Logger.warning("Failed to parse envelope for logging: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning("Failed to log envelope: #{inspect(error)}")
  end

  defp parse_envelope(body) when is_binary(body) do
    # Envelope format: header\nitem_header\nitem_payload[\nitem_header\nitem_payload...]
    # See: https://develop.sentry.dev/sdk/envelopes/

    lines = String.split(body, "\n")

    with {:ok, header_line, rest} <- get_first_line(lines),
         {:ok, envelope_headers} <- Jason.decode(header_line),
         {:ok, items} <- parse_items(rest) do
      envelope = %{
        headers: envelope_headers,
        items: items
      }

      {:ok, envelope}
    else
      error -> {:error, error}
    end
  end

  defp get_first_line([first | rest]), do: {:ok, first, rest}
  defp get_first_line([]), do: {:error, :empty_envelope}

  defp parse_items(lines), do: parse_items(lines, [])

  defp parse_items([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_items([item_header_line, payload_line | rest], acc) do
    with {:ok, _item_header} <- Jason.decode(item_header_line),
         {:ok, payload} <- Jason.decode(payload_line) do
      parse_items(rest, [payload | acc])
    else
      _error ->
        # Skip malformed items
        parse_items(rest, acc)
    end
  end

  defp parse_items([_single_line], acc) do
    # Handle trailing empty line
    {:ok, Enum.reverse(acc)}
  end
end
