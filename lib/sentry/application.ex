defmodule Sentry.Application do
  @moduledoc false

  use Application

  alias Sentry.{Config, Sources}

  @impl true
  def start(_type, _opts) do
    config = Config.validate!()
    :ok = Config.persist(config)

    http_client = Keyword.fetch!(config, :client)

    maybe_http_client_spec =
      if Code.ensure_loaded?(http_client) and function_exported?(http_client, :child_spec, 0) do
        [http_client.child_spec()]
      else
        []
      end

    children =
      [{Registry, keys: :unique, name: Sentry.Transport.SenderRegistry}, Sentry.Dedupe] ++
        maybe_http_client_spec ++
        [Sentry.Transport.SenderPool]

    cache_loaded_applications()
    _ = Sources.load_source_code_map_if_present()

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Sentry.Supervisor) do
      start_integrations(Keyword.fetch!(config, :integrations))
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
      Sentry.Integrations.Oban.Cron.attach_telemetry_handler()
    end

    if config[:oban][:capture_errors] do
      Sentry.Integrations.Oban.ErrorReporter.attach()
    end

    if config[:quantum][:cron][:enabled] do
      Sentry.Integrations.Quantum.Cron.attach_telemetry_handler()
    end
  end
end
