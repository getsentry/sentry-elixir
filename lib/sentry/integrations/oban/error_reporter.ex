defmodule Sentry.Integrations.Oban.ErrorReporter do
  @moduledoc false

  # See this blog post:
  # https://getoban.pro/articles/enhancing-error-reporting

  require Logger

  @spec attach(keyword()) :: :ok
  def attach(config \\ []) when is_list(config) do
    _ =
      :telemetry.attach(
        __MODULE__,
        [:oban, :job, :exception],
        &__MODULE__.handle_event/4,
        config
      )

    :ok
  end

  @spec handle_event(
          [atom(), ...],
          term(),
          %{required(:job) => struct(), optional(term()) => term()},
          keyword()
        ) :: :ok
  def handle_event(
        [:oban, :job, :exception],
        _measurements,
        %{job: job, kind: kind, reason: reason, stacktrace: stacktrace} = _metadata,
        config
      ) do
    if report?(reason) and should_report?(job, config) do
      report(job, kind, reason, stacktrace, config)
    else
      :ok
    end
  end

  defp should_report?(job, config) do
    case Keyword.get(config, :skip_error_report_callback) do
      callback when is_function(callback, 2) ->
        not call_skip_error_report_callback(callback, job)

      _ ->
        true
    end
  end

  defp call_skip_error_report_callback(callback, job) do
    worker =
      case apply(Oban.Worker, :from_string, [job.worker]) do
        {:ok, mod} ->
          mod

        {:error, _} ->
          Logger.warning(
            "Could not resolve Oban worker module from string: #{inspect(job.worker)}"
          )

          nil
      end

    try do
      callback.(worker, job) == true
    rescue
      error ->
        Logger.warning(
          """
          :skip_error_report_callback failed for worker #{inspect(worker)} \
          (job ID #{job.id}):
          
          #{Exception.format(:error, error, __STACKTRACE__)}\
          """
        )

        false
    end
  end

  defp report(job, kind, reason, stacktrace, config) do
    stacktrace =
      case {apply(Oban.Worker, :from_string, [job.worker]), stacktrace} do
        {{:ok, atom_worker}, []} -> [{atom_worker, :process, 1, []}]
        _ -> stacktrace
      end

    base_tags = %{oban_worker: job.worker, oban_queue: job.queue, oban_state: job.state}

    tags = merge_oban_tags(base_tags, config[:oban_tags_to_sentry_tags], job)

    opts =
      [
        stacktrace: stacktrace,
        tags: tags,
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

  defp merge_oban_tags(base_tags, nil, _job), do: base_tags

  defp merge_oban_tags(base_tags, tags_config, job) do
    try do
      custom_tags = call_oban_tags_to_sentry_tags(tags_config, job)

      if is_map(custom_tags) do
        Map.merge(base_tags, custom_tags)
      else
        Logger.warning(
          "oban_tags_to_sentry_tags function returned a non-map value: #{inspect(custom_tags)}"
        )

        base_tags
      end
    rescue
      error ->
        Logger.warning("oban_tags_to_sentry_tags function failed: #{inspect(error)}")

        base_tags
    end
  end

  defp call_oban_tags_to_sentry_tags(fun, job) when is_function(fun, 1) do
    fun.(job)
  end

  defp call_oban_tags_to_sentry_tags({module, function}, job) do
    apply(module, function, [job])
  end
end
