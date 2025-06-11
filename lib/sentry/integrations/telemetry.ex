defmodule Sentry.Integrations.Telemetry do
  @moduledoc """
  Sentry integration for Telemetry.

  *Available since v10.10.0*.
  """

  @moduledoc since: "10.10.0"

  @failure_event [:telemetry, :handler, :failure]

  @doc false
  @spec attach() :: :ok
  def attach do
    _ =
      :telemetry.attach(
        "#{inspect(__MODULE__)}-telemetry-failures",
        @failure_event,
        &__MODULE__.handle_event/4,
        :no_config
      )

    :ok
  end

  @doc false
  @spec handle_event(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          :telemetry.handler_config()
        ) :: :ok
  def handle_event(@failure_event, _measurements, %{} = metadata, :no_config) do
    stacktrace = metadata[:stacktrace] || []
    handler_id = stringified_handler_id(metadata[:handler_id])

    options = [
      stacktrace: stacktrace,
      tags: %{
        telemetry_handler_id: handler_id,
        event_name: inspect(metadata[:event_name])
      }
    ]

    _ =
      case {metadata[:kind], metadata[:reason]} do
        {:error, reason} ->
          exception = Exception.normalize(:error, reason, stacktrace)
          Sentry.capture_exception(exception, options)

        {kind, reason} ->
          options =
            Keyword.merge(options,
              extra: %{kind: inspect(kind), reason: inspect(reason)},
              interpolation_parameters: [handler_id]
            )

          Sentry.capture_message("Telemetry handler %s failed", options)
      end

    :ok
  end

  defp stringified_handler_id(handler_id) when is_binary(handler_id), do: handler_id
  defp stringified_handler_id(handler_id), do: inspect(handler_id)
end
