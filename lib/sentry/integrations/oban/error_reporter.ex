defmodule Sentry.Integrations.Oban.ErrorReporter do
  @moduledoc false

  # See this blog post:
  # https://getoban.pro/articles/enhancing-error-reporting

  alias Sentry.Callback
  alias Sentry.Integrations.Oban.Callbacks

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

  @spec handle_event([atom(), ...], term(), map(), keyword()) :: :ok
  def handle_event([:oban, :job, :exception], measurements, metadata, config) do
    _ =
      Callback.guard(
        describe_failure(metadata),
        fn -> capture_job_exception(measurements, metadata, config) end,
        discard: {:internal_sdk_error, "error"}
      )

    :ok
  end

  defp describe_failure(%{job: %{id: id, worker: worker}}) do
    "Sentry failed to report an Oban job exception for job #{inspect(id)} (#{inspect(worker)})"
  end

  defp describe_failure(_metadata) do
    "Sentry failed to report an Oban job exception"
  end

  defp capture_job_exception(
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
    Callbacks.should_report?(config, :should_report_error_callback, job)
  end

  defp report(job, kind, reason, stacktrace, config) do
    # Oban can hand us a non-list "stacktrace" when a job dies from a gen-call
    # exit (such as a GenServer.call or NimblePool checkout timeout): the value
    # is the `{module, function, args}` from the exit reason rather than a
    # stacktrace. Sentry's :stacktrace option only accepts a list, so anything
    # else would crash this handler (and get it detached). Coerce it away.
    stacktrace = if is_list(stacktrace), do: stacktrace, else: []

    stacktrace =
      case {apply(Oban.Worker, :from_string, [job.worker]), stacktrace} do
        {{:ok, atom_worker}, []} -> [{atom_worker, :process, 1, []}]
        _ -> stacktrace
      end

    base_tags = %{oban_worker: job.worker, oban_queue: job.queue, oban_state: job.state}

    tags = merge_oban_tags(base_tags, config[:oban_tags_to_sentry_tags], job)

    extra =
      job
      |> Map.take([:args, :attempt, :id, :max_attempts, :meta, :queue, :tags, :worker])
      |> Map.update!(:args, &Sentry.Scrubber.scrub/1)

    opts =
      [
        stacktrace: stacktrace,
        tags: tags,
        fingerprint: [job.worker, "{{ default }}"],
        extra: extra,
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
    Callback.run(
      :oban_tags_to_sentry_tags,
      fn ->
        invocation = Callback.to_fun(:oban_tags_to_sentry_tags, tags_config, [job])
        merge_custom_tags(base_tags, invocation.())
      end,
      base_tags,
      context: Callbacks.describe_target(job.worker, job)
    )
  end

  defp merge_custom_tags(base_tags, custom_tags) do
    case Callback.validate(:oban_tags_to_sentry_tags, custom_tags, &is_map/1, "a map") do
      {:ok, custom_tags} -> Map.merge(base_tags, custom_tags)
      :invalid -> base_tags
    end
  end
end
