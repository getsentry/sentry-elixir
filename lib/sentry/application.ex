defmodule Sentry.Application do
  @moduledoc false

  use Application

  alias Sentry.Config

  @impl true
  def start(_type, _opts) do
    config = Config.validate!()
    :ok = Config.persist(config)

    Config.put_config(
      :in_app_module_allow_list,
      Config.in_app_module_allow_list() ++ resolve_in_app_module_allow_list()
    )

    http_client = Keyword.fetch!(config, :client)

    maybe_http_client_spec =
      if Code.ensure_loaded?(http_client) and function_exported?(http_client, :child_spec, 0) do
        [http_client.child_spec()]
      else
        []
      end

    integrations_config = Config.integrations()

    maybe_span_storage =
      if Config.tracing?() do
        [Sentry.OpenTelemetry.SpanStorage]
      else
        []
      end

    children =
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
        [Sentry.Transport.SenderPool]

    cache_loaded_applications()

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Sentry.Supervisor) do
      start_integrations(integrations_config)
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
end
