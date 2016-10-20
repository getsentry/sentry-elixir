defmodule Sentry do
  use Application

  alias Sentry.Event
  require Logger


  @moduledoc """
  Provides the basic functionality to submit a `Sentry.Event` to the Sentry Service.

  ## Configuration

  Add the following to your production config

      config :sentry, dsn: "https://public:secret@app.getsentry.com/1"
        included_environments: [:prod],
        environment_name: :prod,
        tags: %{
          env: "production"
        }

  The `environment_name` and `included_environments` work together to determine
  if and when Sentry should record exceptions. The `environment_name` is the
  name of the current environment. In the example above, we have explicitly set
  the environment to `:prod` which works well if you are inside an environment
  specific configuration `config/prod.exs`.

  An alternative is to use `Mix.env` in your general configuration file:


      config :sentry, dsn: "https://public:secret@app.getsentry.com/1"
        included_environments: [:prod],
        environment_name: Mix.env

  This will set the environment name to whatever the current Mix environment
  atom is, but it will only send events if the current environment is `:prod`,
  since that is the only entry in the `included_environments` key.

  You can even rely on more custom determinations of the environment name. It's
  not uncommmon for most applications to have a "staging" environment. In order
  to handle this without adding an additional Mix environment, you can set an
  environment variable that determines the release level.

      config :sentry, dsn: "https://public:secret@app.getsentry.com/1"
        included_environments: ~w(production staging),
        environment_name: System.get_env("RELEASE_LEVEL") || "development"

  In this example, we are getting the environment name from the `RELEASE_LEVEL`
  environment variable. If that variable does not exist, we default to `"development"`.
  Now, on our servers, we can set the environment variable appropriately. On
  our local development machines, exceptions will never be sent, because the
  default value is not in the list of `include_environments`.

  ## Capturing Exceptions

  Simply calling `capture_exception\2` will send the event.

      Sentry.capture_exception(my_exception)

  ## Configuring The `Logger` Backend

  See `Sentry.Logger`
  """

  @client Application.get_env(:sentry, :client, Sentry.Client)
  @use_error_logger Application.get_env(:sentry, :use_error_logger, false)

  def start(_type, _opts) do
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
    included_environments = Application.get_env(:sentry, :included_environments)
    environment_name = Application.get_env(:sentry, :environment_name)

    if environment_name in included_environments do
      @client.send_event(event)
    else
      {:ok, ""}
    end
  end
end
