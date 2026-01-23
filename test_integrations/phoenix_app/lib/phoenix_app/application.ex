defmodule PhoenixApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Application.ensure_started(:inets)

    # Add the Sentry.LoggerHandler for crash reports and structured logging
    # When enable_logs: true is set in config, logs are also sent to Sentry's Logs Protocol
    :logger.add_handler(:my_sentry_handler, Sentry.LoggerHandler, %{
      config: %{
        # Error capture options
        metadata: [:file, :line],
        # Logs protocol options (requires enable_logs: true in sentry config)
        logs_level: :info,
        logs_excluded_domains: [:cowboy, :ranch],
        logs_metadata: [:request_id, :user_id]
      }
    })

    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryOban.setup()
    OpentelemetryEcto.setup([:phoenix_app, :repo], db_statement: :enabled)
    OpentelemetryLoggerMetadata.setup()

    children = [
      PhoenixAppWeb.Telemetry,
      PhoenixApp.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:phoenix_app, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:phoenix_app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PhoenixApp.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: PhoenixApp.Finch},
      # Start Oban
      {Oban, Application.fetch_env!(:phoenix_app, Oban)},
      # Start to serve requests, typically the last entry
      PhoenixAppWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PhoenixAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    System.get_env("RELEASE_NAME") != nil
  end
end
