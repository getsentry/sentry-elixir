defmodule Sentry do
  use Application

  alias Sentry.Event
  require Logger


  @moduledoc """
    Provides the basic functionality to submit a `Sentry.Event` to the Sentry Service.

    ### Configuration

    Add the following to your production config
        config :sentry_elixir, dsn: "https://public:secret@app.getsentry.com/1"
          included_environments: [:prod],
          environment_name: :prod,
          tags: %{
            env: "production"
          }

    ### Capturing Exceptions

    Simply calling `capture_exception\2` will send the event.

        Sentry.capture_exception(my_exception)

    ### Configuring The `Logger` Backend

    See `Sentry.Logger`

  """

  @client Application.get_env(:sentry_elixir, :client, Sentry.Client)
  @use_error_logger Application.get_env(:sentry_elixir, :use_error_logger, false)

  def start(_type, _opts) do
    check_required_env!()
    children = []
    opts = [strategy: :one_for_one, name: Sentry.Supervisor]


    if @use_error_logger do
      :error_logger.add_report_handler(Sentry.Logger)
    end

    Supervisor.start_link(children, opts)
  end

  @doc """
    Parses and submits an exception to Sentry if current environment is in included_environments.
  """
  @spec capture_exception(Exception.t, Keyword.t) :: {:ok, String.t} | :error
  def capture_exception(exception, opts \\ []) do
    exception
    |> Event.transform_exception(opts)
    |> send_event()
  end

  @doc """
    Sends a `Sentry.Event`
  """
  @spec send_event(%Event{}) :: {:ok, String.t} | :error
  def send_event(%Event{message: nil, exception: nil}) do
    Logger.warn("unable to parse exception")
    {:ok, "Unable to parse as exception, ignoring..."}
  end

  def send_event(event = %Event{}) do
    included_environments = Application.get_env(:sentry, :included_environments, ~w(prod dev test)a)

    if event.environment in included_environments do
      @client.send_event(event)
    else
      {:ok, ""}
    end
  end

  defp check_required_env! do
    case Application.fetch_env(:sentry, :environment_name) do
      {:ok, env} -> env
      :error ->
        case System.get_env("MIX_ENV") do
          nil ->
            raise RuntimeError.exception("environment_name not configured")
          system_env ->
            env = String.to_atom(system_env)
            Application.put_env(:sentry, :environment_name, env)
            env
        end
    end
  end
end
