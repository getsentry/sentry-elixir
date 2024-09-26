defmodule Sentry.Integrations.Oban.Cron do
  @moduledoc false
  alias Sentry.Integrations.CheckInIDMappings

  @events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]

  @spec attach_telemetry_handler(keyword()) :: :ok
  def attach_telemetry_handler(config \\ []) do
    _ = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, config)
    :ok
  end

  @spec handle_event([atom()], term(), term(), keyword()) :: :ok
  def handle_event(event, measurements, metadata, config)

  def handle_event(
        [:oban, :job, event],
        measurements,
        %{job: %mod{meta: %{"cron" => true, "cron_expr" => cron_expr}}} = metadata,
        config
      )
      when event in [:start, :stop, :exception] and mod == Oban.Job and is_binary(cron_expr) do
    _ = handle_oban_job_event(event, measurements, metadata, config)
    :ok
  end

  def handle_event([:oban, :job, event], _measurements, _metadata, _config)
      when event in [:start, :stop, :exception] do
    :ok
  end

  ## Helpers

  defp handle_oban_job_event(:start, _measurements, metadata, config) do
    if opts = job_to_check_in_opts(metadata.job, config) do
      opts
      |> Keyword.merge(status: :in_progress)
      |> Sentry.capture_check_in()
    end
  end

  defp handle_oban_job_event(:stop, measurements, metadata, config) do
    if opts = job_to_check_in_opts(metadata.job, config) do
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

  defp handle_oban_job_event(:exception, measurements, metadata, config) do
    if opts = job_to_check_in_opts(metadata.job, config) do
      opts
      |> Keyword.merge(status: :error, duration: duration_in_seconds(measurements))
      |> Sentry.capture_check_in()
    end
  end

  defp job_to_check_in_opts(job, config) when is_struct(job, Oban.Job) do
    monitor_config_opts = Sentry.Config.integrations()[:monitor_config_defaults]

    monitor_slug =
      case config[:monitor_name_generator] do
        nil -> slugify(job.worker)
        generator when is_function(generator) -> job |> generator.() |> slugify()
      end

    case Keyword.merge(monitor_config_opts, schedule_opts(job)) do
      [] ->
        nil

      monitor_config_opts ->
        id = CheckInIDMappings.lookup_or_insert_new(job.id)

        [
          check_in_id: id,
          # This is already a binary.
          monitor_slug: monitor_slug,
          monitor_config: monitor_config_opts
        ]
    end
  end

  defp schedule_opts(%{meta: meta} = job) when is_struct(job, Oban.Job) do
    case meta["cron_expr"] do
      "@hourly" -> [schedule: [type: :interval, value: 1, unit: :hour]]
      "@daily" -> [schedule: [type: :interval, value: 1, unit: :day]]
      "@weekly" -> [schedule: [type: :interval, value: 1, unit: :week]]
      "@monthly" -> [schedule: [type: :interval, value: 1, unit: :month]]
      "@yearly" -> [schedule: [type: :interval, value: 1, unit: :year]]
      "@annually" -> [schedule: [type: :interval, value: 1, unit: :year]]
      "@reboot" -> []
      cron_expr when is_binary(cron_expr) -> [schedule: [type: :crontab, value: cron_expr]]
      _other -> []
    end
  end

  defp duration_in_seconds(%{duration: duration} = _measurements) do
    duration
    |> System.convert_time_unit(:native, :millisecond)
    |> Kernel./(1000)
  end

  # MyApp.SomeWorker -> "my-app-some-worker"
  defp slugify(worker_name) do
    worker_name
    |> String.split(".")
    |> Enum.map_join("-", &(&1 |> Macro.underscore() |> String.replace("_", "-")))
    |> String.slice(0, 50)
  end
end
