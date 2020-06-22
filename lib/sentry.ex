defmodule Sentry do
  use Application
  alias Sentry.{Config, Event}
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
  will have a source of `:plug`, `Sentry.LoggerBackend` will have a source of `:logger`, and `Sentry.Phoenix.Endpoint` will have a source of `:endpoint`.
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

  Simply calling `capture_exception/2` will send the event. By default, the event
  is sent asynchronously and the result can be awaited upon.  The `:result` option
  can be used to change this behavior.  See `Sentry.Client.send_event/2` for more
  information.

      {:ok, task} = Sentry.capture_exception(my_exception)
      {:ok, event_id} = Task.await(task)
      {:ok, another_event_id} = Sentry.capture_exception(other_exception, [event_source: :my_source, result: :sync])

  ### Options

    * `:event_source` - The source passed as the first argument to `c:Sentry.EventFilter.exclude_exception?/2`

  ## Configuring The `Logger` Backend

  See `Sentry.LoggerBackend`
  """

  @type send_result :: Sentry.Client.send_event_result() | :excluded | :ignored

  def start(_type, _opts) do
    children = [
      {Task.Supervisor, name: Sentry.TaskSupervisor},
      Config.client().child_spec()
    ]

    validate_json_config!()
    validate_log_level_config!()

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
    event_source = Keyword.get(opts, :event_source)

    if filter_module.exclude_exception?(exception, event_source) do
      :excluded
    else
      exception
      |> Event.transform_exception(opts)
      |> send_event(opts)
    end
  end

  @doc """
  Puts the last event ID sent to the server for the current process in
  the process dictionary.
  """
  @spec put_last_event_id_and_source(String.t()) :: {String.t(), atom() | nil} | nil
  def put_last_event_id_and_source(event_id, source \\ nil) when is_binary(event_id) do
    Process.put(:sentry_last_event_id_and_source, {event_id, source})
  end

  @doc """
  Gets the last event ID sent to the server from the process dictionary.
  Since it uses the process dictionary, it will only return the last event
  ID sent within the current process.
  """
  @spec get_last_event_id_and_source() :: {String.t(), atom() | nil} | nil
  def get_last_event_id_and_source do
    Process.get(:sentry_last_event_id_and_source)
  end

  @doc """
  Reports a message to Sentry.

  `opts` argument is passed as the second argument to `Sentry.send_event/2`.
  """
  @spec capture_message(String.t(), Keyword.t()) :: send_result
  def capture_message(message, opts \\ []) when is_binary(message) do
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
    Logger.log(Config.log_level(), "Sentry: unable to parse exception")

    :ignored
  end

  def send_event(%Event{} = event, opts) do
    included_environments = Config.included_environments()
    environment_name = Config.environment_name()

    if environment_name in included_environments do
      Sentry.Client.send_event(event, opts)
    else
      :ignored
    end
  end

  defp validate_json_config!() do
    case Config.json_library() do
      nil ->
        raise ArgumentError.exception("nil is not a valid :json_library configuration")

      library ->
        try do
          with {:ok, %{}} <- library.decode("{}"),
               {:ok, "{}"} <- library.encode(%{}) do
            :ok
          else
            _ ->
              raise ArgumentError.exception(
                      "configured :json_library #{inspect(library)} does not implement decode/1 and encode/1"
                    )
          end
        rescue
          UndefinedFunctionError ->
            reraise ArgumentError.exception("""
                    configured :json_library #{inspect(library)} is not available or does not implement decode/1 and encode/1.
                    Do you need to add #{inspect(library)} to your mix.exs?
                    """),
                    __STACKTRACE__
        end
    end
  end

  defp validate_log_level_config!() do
    value = Config.log_level()

    if value in Config.permitted_log_level_values() do
      :ok
    else
      raise ArgumentError.exception("#{inspect(value)} is not a valid :log_level configuration")
    end
  end
end
