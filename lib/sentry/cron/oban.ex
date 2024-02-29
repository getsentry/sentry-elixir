defmodule Sentry.Cron.Oban do
  @moduledoc false

  @events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]

  @spec attach_telemetry_handler() :: :ok
  def attach_telemetry_handler do
    _ = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, :no_config)
    :ok
  end

  @spec handle_event([atom()], term(), term(), :no_config) :: :ok
  def handle_event([:oban, :job, event], measurements, metadata, _config)
      when event in [:start, :stop, :exception] do
    if is_struct(metadata.job, Oban.Job) and metadata.job.meta["cron"] == true and
         not is_nil(metadata.job.meta["cron_expr"]) do
      handle_event(event, measurements, metadata)
    end

    :ok
  end

  ## Helpers

  defp handle_event(:start, _measurements, metadata) do
    if opts = job_to_check_in_opts(metadata.job) do
      opts
      |> Keyword.merge(status: :in_progress)
      |> Sentry.capture_check_in()
    end
  end

  defp handle_event(:stop, measurements, metadata) do
    if opts = job_to_check_in_opts(metadata.job) do
      status =
        case metadata.state do
          :success -> :ok
          :failure -> :error
          :cancelled -> :ok
          :discard -> :ok
          :snoozed -> :ok
        end

      opts
      |> Keyword.merge(status: status, duration: duration_in_seconds(measurements))
      |> Sentry.capture_check_in()
    end
  end

  defp handle_event(:exception, measurements, metadata) do
    if opts = job_to_check_in_opts(metadata.job) do
      opts
      |> Keyword.merge(status: :error, duration: duration_in_seconds(measurements))
      |> Sentry.capture_check_in()
    end
  end

  defp job_to_check_in_opts(job) when is_struct(job, Oban.Job) do
    if schedule_opts = schedule_opts(job) do
      [
        check_in_id: "oban-#{job.id}",
        # This is already a binary.
        monitor_slug: job.worker,
        monitor_config: [schedule: schedule_opts]
      ]
    else
      nil
    end
  end

  defp schedule_opts(%{meta: meta} = job) when is_struct(job, Oban.Job) do
    case meta["cron_expr"] do
      "@hourly" -> [type: :interval, value: 1, unit: :hour]
      "@daily" -> [type: :interval, value: 1, unit: :day]
      "@weekly" -> [type: :interval, value: 1, unit: :week]
      "@monthly" -> [type: :interval, value: 1, unit: :month]
      "@yearly" -> [type: :interval, value: 1, unit: :year]
      "@annually" -> [type: :interval, value: 1, unit: :year]
      "@reboot" -> nil
      cron_expr when is_binary(cron_expr) -> [type: :crontab, value: cron_expr]
      _other -> nil
    end
  end

  defp duration_in_seconds(%{duration: duration} = _measurements) do
    duration
    |> System.convert_time_unit(:native, :millisecond)
    |> Kernel./(1000)
  end
end
