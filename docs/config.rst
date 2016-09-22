Configuration
=============

Configuration is handled using the standard elixir configuration.

Simply add configuration to the `:sentry` key in the file `config/prod.exs`: 
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

  The name of the environment, this defaults to the `MIX_ENV` environment variable.

.. describe:: DSN

  The DSN provided by Sentry.

Optional settings
------------------

.. describe:: included_environments

  The list of environments you want to send reports to sentry, this defaults to `~w(prod test dev)a`.

.. describe:: tags

  The default tags to send with each report.

.. describe:: release 

  The release to send to sentry with each report. This defaults to nothing.

.. describe:: server_name

  The name of the server to send with each report. This defaults to nothing.

.. describe:: use_error_logger

  Set this to true if you want to capture all exceptions that occur even outside of a request cycle. This
  defaults to false.
