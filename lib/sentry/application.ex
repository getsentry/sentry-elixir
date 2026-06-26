defmodule Sentry.Application do
  @moduledoc false

  use Application

  require Logger

  alias Sentry.Config

  @compile {:no_warn_undefined, [NimbleOwnership]}

  @impl true
  def start(_type, _opts) do
    config = Config.validate!()
    :ok = Config.persist(config)
    :ok = Sentry.Test.Config.maybe_activate()

    Config.put_config(
      :in_app_module_allow_list,
      Config.in_app_module_allow_list() ++ resolve_in_app_module_allow_list()
    )

    http_client = Keyword.fetch!(config, :client)

    maybe_http_client_spec =
      if {:module, http_client} == Code.ensure_loaded(http_client) and
           function_exported?(http_client, :child_spec, 0) do
        [http_client.child_spec()]
      else
        []
      end

    integrations_config = Config.integrations()

    maybe_test_registry =
      if Config.test_mode?() do
        if Code.ensure_loaded?(NimbleOwnership) do
          [
            {NimbleOwnership, name: Sentry.Test.OwnershipServer},
            Sentry.Test.Registry
          ]
        else
          [Sentry.Test.Registry]
        end
      else
        []
      end

    maybe_span_storage =
      if Config.tracing?() do
        [Sentry.OpenTelemetry.SpanStorage]
      else
        []
      end

    telemetry_processor_opts =
      [
        buffer_capacities: Config.telemetry_buffer_capacities(),
        scheduler_weights: Config.telemetry_scheduler_weights(),
        transport_capacity: Config.transport_capacity()
      ]
      |> maybe_put_test_processor_resolver()

    telemetry_processor = [{Sentry.TelemetryProcessor, telemetry_processor_opts}]

    children =
      maybe_test_registry ++
        [
          {Registry, keys: :unique, name: Sentry.Transport.SenderRegistry},
          Sentry.Sources,
          Sentry.Dedupe,
          Sentry.ClientReport.Sender,
          {Sentry.Integrations.CheckInIDMappings,
           [
             max_expected_check_in_time:
               Keyword.fetch!(integrations_config, :max_expected_check_in_time)
           ]}
        ] ++
        maybe_http_client_spec ++
        maybe_span_storage ++
        telemetry_processor ++
        maybe_rate_limiter() ++
        [Sentry.Transport.SenderPool]

    cache_loaded_applications()

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Sentry.Supervisor) do
      start_integrations(integrations_config)
      maybe_add_logger_handler()
      {:ok, pid}
    end
  end

  defp cache_loaded_applications do
    apps_with_vsns =
      if Config.report_deps?() do
        Map.new(Application.loaded_applications(), fn {app, _description, vsn} ->
          {Atom.to_string(app), to_string(vsn)}
        end)
      else
        %{}
      end

    :persistent_term.put({:sentry, :loaded_applications}, apps_with_vsns)
  end

  defp start_integrations(config) do
    if config[:oban][:cron][:enabled] do
      Sentry.Integrations.Oban.Cron.attach_telemetry_handler(config[:oban][:cron])
    end

    if config[:oban][:capture_errors] do
      Sentry.Integrations.Oban.ErrorReporter.attach(config[:oban])
    end

    if config[:quantum][:cron][:enabled] do
      Sentry.Integrations.Quantum.Cron.attach_telemetry_handler()
    end

    if config[:telemetry][:report_handler_failures] do
      Sentry.Integrations.Telemetry.attach()
    end
  end

  defp resolve_in_app_module_allow_list do
    Enum.flat_map(Config.in_app_otp_apps(), fn app ->
      case :application.get_key(app, :modules) do
        {:ok, modules} -> modules
        _ -> []
      end
    end)
  end

  defp maybe_add_logger_handler do
    if Config.enable_logs?() do
      # The :logs config drives both backends of the auto-attached handler: LogsBackend
      # reads its options (level, excluded_domains, metadata) from Config at runtime,
      # while the ErrorBackend options are passed here at attach time. The error-event
      # options come from the separate :capture_* keys so they stay independent from the
      # Logs UI ones (e.g. error-event metadata/excluded_domains are opt-in).
      handler_config = %{
        level: Config.logs_capture_level(),
        capture_log_messages: Config.logs_capture_log_messages?(),
        metadata: Config.logs_capture_metadata(),
        excluded_domains: Config.logs_capture_excluded_domains()
      }

      cond do
        # The auto handler is still registered, which happens when the :sentry application
        # is stopped and restarted within the same VM: the handler lives in :logger, not in
        # our supervision tree, so it survives the stop. Re-sync its config so updated :logs
        # settings reach the ErrorBackend, whose options are frozen at attach time and would
        # otherwise stay stale across the restart.
        auto_logger_handler_registered?() ->
          _ = :logger.update_handler_config(:sentry_log_handler, :config, handler_config)
          :ok

        # A user registered their own Sentry.LoggerHandler; don't attach the auto one to
        # avoid duplicate capture.
        sentry_logger_handler_registered?() ->
          :ok

        true ->
          case :logger.add_handler(:sentry_log_handler, Sentry.LoggerHandler, %{
                 config: handler_config
               }) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("[Sentry] Failed to add logger handler: #{inspect(reason)}")
          end
      end
    else
      _ = :logger.remove_handler(:sentry_log_handler)
    end

    :ok
  end

  defp auto_logger_handler_registered? do
    match?({:ok, _config}, :logger.get_handler_config(:sentry_log_handler))
  end

  defp sentry_logger_handler_registered? do
    :logger.get_handler_config()
    |> Enum.any?(fn %{module: module} -> module == Sentry.LoggerHandler end)
  end

  # In tests, we do not run a global rate limiter; tests start their own when
  # they need it.
  if Mix.env() == :test do
    defp maybe_rate_limiter, do: []
  else
    defp maybe_rate_limiter, do: [Sentry.Transport.RateLimiter]
  end

  defp maybe_put_test_processor_resolver(opts) do
    if Config.test_mode?() do
      Keyword.put(opts, :processor_resolver, &Sentry.Test.Registry.lookup_processor_for/1)
    else
      opts
    end
  end
end
