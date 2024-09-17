defmodule PhoenixApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PhoenixAppWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:phoenix_app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PhoenixApp.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: PhoenixApp.Finch},
      # Start a worker by calling: PhoenixApp.Worker.start_link(arg)
      # {PhoenixApp.Worker, arg},
      # Start to serve requests, typically the last entry
      PhoenixAppWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # TODO: Uncomment if we ever move the endpoint from test/support to the phoenix_app dir
  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  # @impl true
  # def config_change(changed, _new, removed) do
  #   PhoenixAppWeb.Endpoint.config_change(changed, removed)
  #   :ok
  # end
end
