defmodule Sentry do
  use Application
  import Supervisor.Spec
  alias Sentry.{Event, Config}
  require Logger

  @moduledoc """
  Provides the basic functionality to submit a `Sentry.Event` to the Sentry Service.

  ## Configuration

  Add the following to your production config

      config :sentry, dsn: "https://public:secret@app.getsentry.com/1",
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

      config :sentry, dsn: "https://public:secret@app.getsentry.com/1",
        included_environments: [:prod],
        environment_name: Mix.env

  This will set the environment name to whatever the current Mix environment
  atom is, but it will only send events if the current environment is `:prod`,
  since that is the only entry in the `included_environments` key.

  You can even rely on more custom determinations of the environment name. It's
  not uncommmon for most applications to have a "staging" environment. In order
  to handle this without adding an additional Mix environment, you can set an
  environment variable that determines the release level.

      config :sentry, dsn: "https://public:secret@app.getsentry.com/1",
        included_environments: ~w(production staging),
        environment_name: System.get_env("RELEASE_LEVEL") || "development"

  In this example, we are getting the environment name from the `RELEASE_LEVEL`
  environment variable. If that variable does not exist, we default to `"development"`.
  Now, on our servers, we can set the environment variable appropriately. On
  our local development machines, exceptions will never be sent, because the
  default value is not in the list of `included_environments`.

  ## Filtering Exceptions

  If you would like to prevent certain exceptions, the `:filter` configuration option
  allows you to implement the `Sentry.EventFilter` behaviour.  The first argument is the
  exception to be sent, and the second is the source of the event.  `Sentry.Plug`
  will have a source of `:plug`, and `Sentry.Logger` will have a source of `:logger`.
  If an exception does not come from either of those sources, the source will be nil
  unless the `:event_source` option is passed to `Sentry.capture_exception/2`

  A configuration like below will prevent sending `Phoenix.Router.NoRouteError` from `Sentry.Plug`, but
  allows other exceptions to be sent.

      # sentry_event_filter.ex
      defmodule MyApp.SentryEventFilter do
        @behaviour Sentry.EventFilter

        def exclude_exception?(%Elixir.Phoenix.Router.NoRouteError{}, :plug), do: true
        def exclude_exception?(_exception, _source), do: false
      end

      # config.exs
      config :sentry, filter: MyApp.SentryEventFilter,
        included_environments: ~w(production staging),
        environment_name: System.get_env("RELEASE_LEVEL") || "development"

  ## Capturing Exceptions

  Simply calling `capture_exception/2` will send the event.  By default, the event is sent asynchronously and the result can be awaited upon.  The `:result` option can be used to change this behavior.  See `Sentry.Client.send_event/2` for more information.

      {:ok, task} = Sentry.capture_exception(my_exception)
      {:ok, event_id} = Task.await(task)

      {:ok, another_event_id} = Sentry.capture_exception(other_exception, [event_source: :my_source, result: :sync])

  ### Options
    * `:event_source` - The source passed as the first argument to `Sentry.EventFilter.exclude_exception?/2`

  ## Configuring The `Logger` Backend

  See `Sentry.Logger`
  """

  @type send_result :: Sentry.Client.send_event_result() | :excluded | :ignored

  def start(_type, _opts) do
    children = [
      supervisor(Task.Supervisor, [[name: Sentry.TaskSupervisor]]),
      :hackney_pool.child_spec(
        Sentry.Client.hackney_pool_name(),
        timeout: Config.hackney_timeout(),
        max_connections: Config.max_hackney_connections()
      )
    ]

    opts = [strategy: :one_for_one, name: Sentry.Supervisor]

    Supervisor.start_link(children, opts)
  end

  @doc """
  Parses and submits an exception to Sentry if current environment is in included_environments.
  `opts` argument is passed as the second argument to `Sentry.send_event/2`.
  """
  @spec capture_exception(Exception.t(), Keyword.t()) :: send_result
  def capture_exception(exception, opts \\ []) do
    filter_module = Config.filter()
    {source, opts} = Keyword.pop(opts, :event_source)

    if filter_module.exclude_exception?(exception, source) do
      :excluded
    else
      exception
      |> Event.transform_exception(opts)
      |> send_event(opts)
    end
  end

  @doc """
  Reports a message to Sentry.

  `opts` argument is passed as the second argument to `Sentry.send_event/2`.
  """
  @spec capture_message(String.t(), Keyword.t()) :: send_result
  def capture_message(message, opts \\ []) do
    opts
    |> Keyword.put(:message, message)
    |> Event.create_event()
    |> send_event(opts)
  end

  @doc """
  Sends a `Sentry.Event`

  `opts` argument is passed as the second argument to `send_event/2` of the configured `Sentry.HTTPClient`.  See `Sentry.Client.send_event/2` for more information.
  """
  @spec send_event(Event.t(), Keyword.t()) :: send_result
  def send_event(event, opts \\ [])

  def send_event(%Event{message: nil, exception: nil}, _opts) do
    Logger.warn("Sentry: unable to parse exception")

    :ignored
  end

  def send_event(%Event{} = event, opts) do
    included_environments = Config.included_environments()
    environment_name = Config.environment_name()
    client = Config.client()

    if environment_name in included_environments do
      client.send_event(event, opts)
    else
      :ignored
    end
  end
end
