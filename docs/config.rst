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

Required settings
------------------

.. describe:: environment_name

  The name of the environment, this defaults to the ``:dev`` environment variable.

.. describe:: dsn

  The DSN provided by Sentry.

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

.. describe:: use_error_logger

  Set this to true if you want to capture all exceptions that occur even outside of a request cycle. This
  defaults to false.

.. describe:: filter

  Set this to a module that implements the ``Sentry.EventFilter`` behaviour if you would like to prevent
  certain exceptions from being sent.  See below for further documentation.

.. describe:: hackney_opts

  Sentry uses [hackney](https://github.com/benoitc/hackney).  If you would like to set [options](https://github.com/benoitc/hackney/blob/master/doc/hackney.md#request5) for hackney requests, they can be provided via this configuration.

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
