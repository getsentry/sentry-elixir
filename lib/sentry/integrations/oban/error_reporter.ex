defmodule Sentry.Integrations.Oban.ErrorReporter do
  @moduledoc false

  # See this blog post:
  # https://getoban.pro/articles/enhancing-error-reporting

  @spec attach() :: :ok
  def attach do
    _ =
      :telemetry.attach(
        __MODULE__,
        [:oban, :job, :exception],
        &__MODULE__.handle_event/4,
        :no_config
      )

    :ok
  end

  @spec handle_event(
          [atom(), ...],
          term(),
          %{required(:job) => struct(), optional(term()) => term()},
          :no_config
        ) :: :ok
  def handle_event(
        [:oban, :job, :exception],
        _measurements,
        %{job: job, kind: kind, reason: reason, stacktrace: stacktrace} = _metadata,
        :no_config
      ) do
    if report?(reason) do
      report(job, kind, reason, stacktrace)
    else
      :ok
    end
  end

  defp report(job, kind, reason, stacktrace) do
    stacktrace =
      case {apply(Oban.Worker, :from_string, [job.worker]), stacktrace} do
        {{:ok, atom_worker}, []} -> [{atom_worker, :process, 1, []}]
        _ -> stacktrace
      end

    opts =
      [
        stacktrace: stacktrace,
        tags: %{oban_worker: job.worker, oban_queue: job.queue, oban_state: job.state},
        fingerprint: [job.worker, "{{ default }}"],
        extra:
          Map.take(job, [:args, :attempt, :id, :max_attempts, :meta, :queue, :tags, :worker]),
        integration_meta: %{oban: %{job: job}}
      ]

    _ =
      case maybe_unwrap_exception(kind, reason, stacktrace) do
        exception when is_exception(exception) ->
          Sentry.capture_exception(exception, opts)

        _other ->
          message =
            case kind do
              :exit -> "Oban job #{job.worker} exited: %s"
              :throw -> "Oban job #{job.worker} exited with an uncaught throw: %s"
              _other -> "Oban job #{job.worker} errored out: %s"
            end

          Sentry.capture_message(message, opts ++ [interpolation_parameters: [inspect(reason)]])
      end

    :ok
  end

  # Oban.PerformError also wraps {:discard, _} and {:cancel, _} tuples, but those are
  # not *errors* and should not be reported to Sentry automatically.
  defp report?(%{reason: {type, _reason}} = error) when is_exception(error, Oban.PerformError) do
    type == :error
  end

  defp report?(_error) do
    true
  end

  defp maybe_unwrap_exception(
         :error = _kind,
         %{reason: {:error, error}} = perform_error,
         _stacktrace
       )
       when is_exception(perform_error, Oban.PerformError) and is_exception(error) do
    error
  end

  defp maybe_unwrap_exception(kind, reason, stacktrace) do
    Exception.normalize(kind, reason, stacktrace)
  end
end
