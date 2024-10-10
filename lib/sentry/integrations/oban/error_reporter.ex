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
  def handle_event([:oban, :job, :exception], _measurements, %{job: job} = _metadata, :no_config) do
    %{reason: reason, stacktrace: stacktrace} = job.unsaved_error

    stacktrace =
      case {apply(Oban.Worker, :from_string, [job.worker]), stacktrace} do
        {{:ok, atom_worker}, []} -> [{atom_worker, :process, 1, []}]
        _ -> stacktrace
      end

    _ =
      if is_exception(reason) do
        Sentry.capture_exception(reason,
          stacktrace: stacktrace,
          tags: %{oban_worker: job.worker, oban_queue: job.queue, oban_state: job.state},
          fingerprint: [
            inspect(reason.__struct__),
            inspect(job.worker),
            Exception.message(reason)
          ],
          extra:
            Map.take(job, [:args, :attempt, :id, :max_attempts, :meta, :queue, :tags, :worker]),
          integration_meta: %{oban: %{job: job}}
        )
      else
        Sentry.capture_message("Error with %s", interpolation_parameters: [reason])
      end

    :ok
  end
end
