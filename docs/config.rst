Configuration
=============

Configuration is handled using the standard Elixir configuration.

Simply add configuration to the ``:sentry`` key in the file ``config/prod.exs``:

.. code-block:: elixir

  config :sentry,
    dsn: "https://public:secret@app.getsentry.com/1"

If using an environment with Plug or Phoenix add the following to your router:

.. code-block:: elixir

  use Plug.ErrorHandler
  use Sentry.Plug

If you'd like to capture errors from separate processes like `Task` that may crash, add the line ``:ok = :error_logger.add_report_handler(Sentry.Logger)`` to your application's start function:

.. code-block:: elixir

  def start(_type, _opts) do
    children = [
      supervisor(Task.Supervisor, [[name: Sentry.TaskSupervisor]]),
      :hackney_pool.child_spec(Sentry.Client.hackney_pool_name(),  [timeout: Config.hackney_timeout(), max_connections: Config.max_hackney_connections()])
    ]
    opts = [strategy: :one_for_one, name: Sentry.Supervisor]

    :ok = :error_logger.add_report_handler(Sentry.Logger)

    Supervisor.start_link(children, opts)
  end

Required settings
------------------

.. describe:: environment_name

  The name of the environment, this defaults to the ``:dev`` environment variable.

.. describe:: dsn

  The DSN provided by Sentry.

.. describe:: root_source_code_path

  This is only required if ``enable_source_code_context`` is enabled.  Should generally be set to ``File.cwd!``.

Optional settings
------------------

.. describe:: included_environments

  The list of environments you want to send reports to sentry, this defaults to ``~w(prod test dev)a``.

.. describe:: tags

  The default tags to send with each report.

.. describe:: release

  The release to send to sentry with each report. This defaults to nothing.

.. describe:: server_name

  The name of the server to send with each report. This defaults to nothing.

.. describe:: client

  If you need different functionality for the HTTP client, you can define your own module that implements the `Sentry.HTTPClient` behaviour and set `client` to that module.

.. describe:: filter

  Set this to a module that implements the ``Sentry.EventFilter`` behaviour if you would like to prevent
  certain exceptions from being sent.  See below for further documentation.

.. describe:: hackney_pool_max_connections

  Number of connections for Sentry's hackney pool.  This defaults to 50.

.. describe:: hackney_pool_timeout

  Timeout for Sentry's hackney pool.  This defaults to 5000 milliseconds.

.. describe:: hackney_opts

  Sentry starts its own hackney pool named ``:sentry_pool``, and defaults to using it.  Hackney's ``pool`` configuration as well others like proxy or response timeout can be set through this configuration as it is passed directly to hackney when making a request.

.. describe:: before_send_event

  This option allows performing operations on the event before it is sent by ``Sentry.Client``.  Accepts an anonymous function or a {module, function} tuple, and the event will be passed as the only argument.

.. describe:: after_send_event

  This option allows performing arbitrary operations after attempting to send an event.  Accepts an anonymous function or a {module, function} tuple, and the event will be passed as the first argument, and the result of sending the event will be passed as the second argument.

.. describe:: sample_rate

  The sampling factor to apply to events.  A value of 0.0 will deny sending any events, and a value of 1.0 will send 100% of events.

.. describe:: in_app_module_whitelist

  Expects a list of modules that is used to distinguish among stacktrace frames that belong to your app and ones that are part of libraries or core Elixir.  This is used to better display the significant part of stacktraces.  The logic is greedy, so if your app's root module is ``MyApp`` and your setting is ``[MyApp]``, that module as well as any submodules like ``MyApp.Submodule`` would be considered part of your app.  Defaults to ``[]``.

.. describe:: report_deps

  Will attempt to load Mix dependencies at runtime to report alongside events.  Defaults to `true`.

.. describe:: enable_source_code_context

  When true, Sentry will read and store source code files to report the source code that caused an exception.

.. describe:: context_lines

  The number of lines of source code before and after the line that caused the exception to be included.  Defaults to ``3``.

.. describe:: source_code_exclude_patterns

  A list of Regex expressions used to exclude file paths that should not be stored or referenced when reporting exceptions.  Defaults to ``[~r"/_build/", ~r"/deps/", ~r"/priv/"]``.

.. describe:: source_code_path_pattern

  A glob that is expanded to select files from the ``:root_source_code_path``.  Defaults to ``"**/*.ex"``.

Testing Your Configuration
--------------------------

To ensure you've set up your configuration correctly we recommend running the
included mix task.  It can be tested on different Mix environments and will tell you if it is not currently configured to send events in that environment:

.. code-block:: bash

  $ MIX_ENV=dev mix sentry.send_test_event
  Client configuration:
  server: https://sentry.io/
  public_key: public
  secret_key: secret
  included_environments: [:prod]
  current environment_name: :dev

  :dev is not in [:prod] so no test event will be sent

  $ MIX_ENV=prod mix sentry.send_test_event
  Client configuration:
  server: https://sentry.io/
  public_key: public
  secret_key: secret
  included_environments: [:prod]
  current environment_name: :prod

  Sending test event!
