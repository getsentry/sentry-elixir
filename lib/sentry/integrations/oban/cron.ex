defmodule Sentry.Integrations.Oban.Cron do
  @moduledoc """
  This module provides built-in integration for cron jobs managed by Oban.
  """

  @moduledoc since: "10.9.0"

  alias Sentry.Callback
  alias Sentry.Integrations.CheckInIDMappings
  alias Sentry.Integrations.Oban.Callbacks

  @doc """
  The Oban integration calls this callback (if present) to customize
  the configuration options for the check-in.

  This function must return options compatible with the ones passed to `Sentry.CheckIn.new/1`.

  Options returned by this function overwrite any option inferred by the specific
  integration for the check in. We perform *deep merging* of nested keyword options.

  If this callback raises, throws, or exits, the failure is logged at the `:error` level with
  the `:sentry` logger domain, and the check-in is still sent with the options the integration
  inferred and nothing merged into them. Since those options include the monitor slug, a
  check-in that this callback was meant to redirect goes to the monitor named after the worker
  instead. See the [*Crashing Callbacks*](`m:Sentry#module-crashing-callbacks`) section of the
  `Sentry` documentation for more information.
  """
  @doc since: "10.9.0"
  @callback sentry_check_in_configuration(oban_job :: struct()) :: options_to_merge :: keyword()

  @events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]

  @doc false
  @spec attach_telemetry_handler(keyword()) :: :ok
  def attach_telemetry_handler(config) when is_list(config) do
    _ = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, config)
    :ok
  end

  @doc false
  @spec handle_event([atom()], term(), term(), keyword()) :: :ok
  def handle_event(event, measurements, metadata, config)

  def handle_event(
        [:oban, :job, event],
        measurements,
        %{job: %mod{meta: %{"cron" => true, "cron_expr" => cron_expr}}} = metadata,
        config
      )
      when event in [:start, :stop, :exception] and mod == Oban.Job and is_binary(cron_expr) do
    _ =
      Callback.guard(
        describe_failure(metadata.job),
        fn -> handle_oban_job_event(event, measurements, metadata, config) end,
        discard: {:internal_sdk_error, "monitor"}
      )

    :ok
  end

  def handle_event([:oban, :job, event], _measurements, _metadata, _config)
      when event in [:start, :stop, :exception] do
    :ok
  end

  ## Helpers

  defp describe_failure(job) do
    "Sentry failed to report an Oban check-in for job #{inspect(job.id)} " <>
      "(#{inspect(job.worker)})"
  end

  defp handle_oban_job_event(:start, _measurements, metadata, config) do
    if opts = job_to_check_in_opts(metadata.job, config) do
      opts
      |> Keyword.merge(status: :in_progress)
      |> Sentry.capture_check_in()
    end
  end

  # A snoozed job is rescheduled rather than finished, so its check-in stays open
  # until the run that actually completes closes it.
  defp handle_oban_job_event(:stop, _measurements, %{state: :snoozed}, _config) do
    :ok
  end

  defp handle_oban_job_event(:stop, measurements, metadata, config) do
    status =
      case metadata.state do
        :success -> :ok
        :failure -> :error
        :cancelled -> :ok
        :discard -> :ok
      end

    maybe_capture_check_in(status, measurements, metadata, config)
  end

  defp handle_oban_job_event(:exception, measurements, metadata, config) do
    maybe_capture_check_in(:error, measurements, metadata, config)
  end

  defp maybe_capture_check_in(status, measurements, metadata, config) do
    if status != :error or should_report_error_check_in?(metadata.job, config) do
      if opts = job_to_check_in_opts(metadata.job, config) do
        opts
        |> Keyword.merge(status: status, duration: duration_in_seconds(measurements))
        |> Sentry.capture_check_in()
      end
    end
  end

  defp should_report_error_check_in?(job, config) do
    Callbacks.should_report?(config, :should_report_error_check_in_callback, job)
  end

  defp job_to_check_in_opts(job, config) when is_struct(job, Oban.Job) do
    # Check schedule first - if empty (e.g., @reboot), skip check-in entirely
    # since @reboot can't be expressed as a cron/interval schedule
    case schedule_opts(job) do
      [] ->
        nil

      schedule_opts ->
        monitor_config_opts = Sentry.Config.integrations()[:monitor_config_defaults]
        monitor_config_opts = maybe_put_timezone_option(monitor_config_opts, job)
        monitor_config_opts = Keyword.merge(monitor_config_opts, schedule_opts)

        monitor_slug = monitor_slug(job, config[:monitor_slug_generator])

        id = CheckInIDMappings.lookup_or_insert_new(job.id)

        opts = [
          check_in_id: id,
          # This is already a binary.
          monitor_slug: monitor_slug,
          monitor_config: monitor_config_opts
        ]

        resolve_custom_opts(opts, job)
    end
  end

  defp resolve_custom_opts(opts, %{worker: worker} = job)
       when is_struct(job, Oban.Job) and is_binary(worker) do
    job.worker |> String.split(".") |> Module.safe_concat()
  rescue
    ArgumentError -> opts
  else
    worker ->
      if Code.ensure_loaded?(worker) do
        resolve_custom_opts(opts, worker, job)
      else
        opts
      end
  end

  defp resolve_custom_opts(options, mod, per_integration_term) do
    custom_opts =
      if function_exported?(mod, :sentry_check_in_configuration, 1) do
        Callback.run(
          :sentry_check_in_configuration,
          fn -> mod.sentry_check_in_configuration(per_integration_term) end,
          [],
          context: Callbacks.describe_target(mod, per_integration_term)
        )
      else
        []
      end

    deep_merge_keyword(options, custom_opts)
  end

  defp monitor_slug(job, nil) do
    slugify(job.worker)
  end

  defp monitor_slug(job, {mod, fun}) when is_atom(mod) and is_atom(fun) do
    Callback.run(
      :monitor_slug_generator,
      fn -> mod |> apply(fun, [job]) |> slugify() end,
      slugify(job.worker),
      context: Callbacks.describe_target(job.worker, job)
    )
  end

  defp deep_merge_keyword(left, right) do
    Keyword.merge(left, right, fn _key, left_val, right_val ->
      if Keyword.keyword?(left_val) and Keyword.keyword?(right_val) do
        deep_merge_keyword(left_val, right_val)
      else
        right_val
      end
    end)
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

  defp maybe_put_timezone_option(opts, %{meta: %{"cron_tz" => tz}} = _job) do
    Keyword.put(opts, :timezone, tz)
  end

  defp maybe_put_timezone_option(opts, _job) do
    opts
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
