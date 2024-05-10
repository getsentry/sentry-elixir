defmodule Sentry.Integrations.Quantum.Cron do
  @moduledoc false

  require Logger

  @events [
    [:quantum, :job, :start],
    [:quantum, :job, :stop],
    [:quantum, :job, :exception]
  ]

  @spec attach_telemetry_handler() :: :ok
  def attach_telemetry_handler do
    _ = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, :no_config)
    :ok
  end

  @spec handle_event([atom()], term(), term(), :no_config) :: :ok
  def handle_event(event, measurements, metadata, _config)

  def handle_event(
        [:quantum, :job, event],
        measurements,
        %{job: %mod{schedule: schedule}} = metadata,
        _config
      )
      when event in [:start, :stop, :exception] and mod == Quantum.Job and not is_nil(schedule) do
    _ = handle_event(event, measurements, metadata)
    :ok
  end

  def handle_event([:quantum, :job, event], _measurements, _metadata, _config)
      when event in [:start, :stop, :exception] do
    :ok
  end

  ## Helpers

  defp handle_event(:start, _measurements, metadata) do
    if opts = check_in_opts(metadata) do
      opts
      |> Keyword.merge(status: :in_progress)
      |> Sentry.capture_check_in()
    end
  end

  defp handle_event(:stop, measurements, metadata) do
    if opts = check_in_opts(metadata) do
      opts
      |> Keyword.merge(status: :ok, duration: duration_in_seconds(measurements))
      |> Sentry.capture_check_in()
    end
  end

  defp handle_event(:exception, measurements, metadata) do
    if opts = check_in_opts(metadata) do
      opts
      |> Keyword.merge(status: :error, duration: duration_in_seconds(measurements))
      |> Sentry.capture_check_in()
    end
  end

  defp check_in_opts(%{job: job} = metadata) when is_struct(job, Quantum.Job) do
    if schedule_opts = schedule_opts(job) do
      id = metadata.telemetry_span_context |> :erlang.phash2() |> Integer.to_string()

      [
        check_in_id: "quantum-#{id}",
        # This is already a binary.
        monitor_slug: "quantum-#{slugify(job.name)}",
        monitor_config: [schedule: schedule_opts]
      ]
    else
      nil
    end
  end

  defp schedule_opts(job) when is_struct(job, Quantum.Job) do
    case apply(Crontab.CronExpression.Composer, :compose, [job.schedule]) do
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

  defp slugify(job_name) when is_reference(job_name) do
    Logger.error(
      """
      Sentry cannot report Quantum cron jobs correctly if they don't have a :name set up, and \
      will just report them as "quantum-generic-job".\
      """,
      event_source: :logger
    )

    "generic-job"
  end

  defp slugify(job_name) when is_atom(job_name) do
    case Atom.to_string(job_name) do
      "Elixir." <> module -> module |> Macro.underscore() |> slugify()
      other -> slugify(other)
    end
  end

  defp slugify(job_name) when is_binary(job_name) do
    job_name
    |> String.downcase()
    |> String.replace(["_", "#", "<", ">", ".", " ", "/"], "-")
    |> String.slice(0, 50)
  end
end
