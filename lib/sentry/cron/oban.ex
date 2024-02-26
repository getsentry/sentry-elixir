defmodule Sentry.Cron.Oban do
  @moduledoc false

  @events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]

  @spec attach_telemetry_handler() :: :ok
  def attach_telemetry_handler do
    _ = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, %{})
    :ok
  end

  @spec handle_event([atom()], term(), term(), term()) :: term()
  def handle_event(event, measurements, metadata, config)

  def handle_event([:oban, :job, :start], _measurements, metadata, _config) do
    Sentry.capture_check_in(
      check_in_id: job_id(metadata.job),
      status: :in_progress,
      monitor_slug: job_to_monitor_slug(metadata.job)
    )
  end

  def handle_event([:oban, :job, :stop], measurements, metadata, _config) do
    status =
      case metadata.state do
        :success -> :ok
        :failure -> :error
        :cancelled -> :ok
        :discard -> :ok
        :snoozed -> :ok
      end

    Sentry.capture_check_in(
      check_in_id: job_id(metadata.job),
      status: status,
      monitor_slug: job_to_monitor_slug(metadata.job),
      duration: duration_in_seconds(measurements)
    )
  end

  def handle_event([:oban, :job, :exception], measurements, metadata, _config) do
    Sentry.capture_check_in(
      check_in_id: job_id(metadata.job),
      status: :error,
      monitor_slug: job_to_monitor_slug(metadata.job),
      duration: duration_in_seconds(measurements)
    )
  end

  defp job_id(job) when is_struct(job, Oban.Job) do
    "oban-#{job.id}"
  end

  defp job_to_monitor_slug(job) when is_struct(job, Oban.Job) do
    # This is already a binary.
    job.worker
  end

  defp duration_in_seconds(%{duration: duration} = _measurements) do
    duration
    |> System.convert_time_unit(:native, :millisecond)
    |> Kernel./(1000)
  end
end
