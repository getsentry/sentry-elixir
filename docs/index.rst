.. sentry:edition:: self

   Sentry-Elixir
   =============

.. sentry:edition:: on-premise, hosted

    .. class:: platform-elixir

    Elixir
    ======

The Elixir SDK for Sentry.

Installation
------------

Edit your mix.exs file to add it as a dependency and add the ``:sentry`` package to your applications:

.. code-block:: elixir

  defp application do
   [applications: [:sentry, :logger]]
  end

  defp deps do
    [{:sentry, "~> 6.3"}]
  end

Configuration
-------------

Setup the application production environment in your ``config/prod.exs``

.. code-block:: elixir

  config :sentry,
    dsn: "___PUBLIC_DSN___",
    environment_name: :prod,
    enable_source_code_context: true,
    root_source_code_path: File.cwd!,
    tags: %{
      env: "production"
    },
    included_environments: [:prod]


The ``environment_name`` and ``included_environments`` work together to determine
if and when Sentry should record exceptions. The ``environment_name`` is the
name of the current environment. In the example above, we have explicitly set
the environment to ``:prod`` which works well if you are inside an environment
specific configuration like ``config/prod.exs``.

An alternative is to use ``Mix.env`` in your general configuration file:

.. code-block:: elixir

  config :sentry, dsn: "___PUBLIC_DSN___"
     included_environments: [:prod],
     environment_name: Mix.env

This will set the environment name to whatever the current Mix environment
atom is, but it will only send events if the current environment is ``:prod``,
since that is the only entry in the ``included_environments`` key.

You can even rely on more custom determinations of the environment name. It's
not uncommon for most applications to have a "staging" environment. In order
to handle this without adding an additional Mix environment, you can set an
environment variable that determines the release level.

.. code-block:: elixir

  config :sentry, dsn: "___PUBLIC_DSN___"
    included_environments: ~w(production staging),
    environment_name: System.get_env("RELEASE_LEVEL") || "development"

In this example, we are getting the environment name from the ``RELEASE_LEVEL``
environment variable. If that variable does not exist, we default to ``"development"``.
Now, on our servers, we can set the environment variable appropriately. On
our local development machines, exceptions will never be sent, because the
default value is not in the list of ``included_environments``.

If using an environment with Plug or Phoenix add the following to your router:

.. code-block:: elixir

  use Plug.ErrorHandler
  use Sentry.Plug


Adding Context
--------------

Sentry allows a user to provide context to all error reports, Elixir being multi-process makes this a special
case. When setting a context we store that context in the process dictionary, which means if you spin up a
new process and it fails you might lose your context. That said using the context is simple:

.. code-block:: elixir

  # sets the logged in user
  Sentry.Context.set_user_context(%{email: "foo@example.com"})

  # sets the tag of interesting
  Sentry.Context.set_tags_context(%{interesting: "yes"})

  # sends any additional context
  Sentry.Context.set_extra_context(%{my: "context"})

  # adds an breadcrumb to the request to help debug
  Sentry.Context.add_breadcrumb(%{my: "crumb"})

Filtering Events
----------------

If you would like to prevent certain exceptions, the ``:filter`` configuration option
allows you to implement the ``Sentry.EventFilter`` behaviour.  The first argument is the
exception to be sent, and the second is the source of the event.  ``Sentry.Plug``
will have a source of ``:plug``, ``Sentry.Logger`` will have a source of ``:logger``, and ``Sentry.Phoenix.Endpoint`` will have a source of ``:endpoint``.
If an exception does not come from either of those sources, the source will be nil
unless the ``:event_source`` option is passed to ``Sentry.capture_exception/2``

A configuration like below will prevent sending ``Phoenix.Router.NoRouteError`` from ``Sentry.Plug``, but
allows other exceptions to be sent.

.. code-block:: elixir

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

Including Source Code
---------------------

Sentry's server supports showing the source code that caused an error, but depending on deployment, the source code for an application is not guaranteed to be available while it is running.  To work around this, the Sentry library reads and stores the source code at compile time. This has some unfortunate implications.  If a file is changed, and Sentry is not recompiled, it will still report old source code.

The best way to ensure source code is up to date is to recompile Sentry itself via ``mix deps.compile sentry --force``.  It's possible to create a Mix Task alias in ``mix.exs`` to do this.  The example below would allow one to run ``mix.sentry_recompile`` which will force recompilation of Sentry so it has the newest source and then compile the project:

.. code-block:: elixir

  # mix.exs
  defp aliases do
    [sentry_recompile: ["deps.compile sentry --force", "compile"]]
  end

To enable, set ``:enable_source_code_context`` and ``root_source_code_path``:

.. code-block:: elixir

  config :sentry,
    enable_source_code_context: true,
    root_source_code_path: File.cwd!

For more documentation, see `Sentry.Sources <https://hexdocs.pm/sentry/Sentry.Sources.html>`_.

Deep Dive
---------

Want more?  Have a look at the full documentation for more information.

.. toctree::
   :maxdepth: 2
   :titlesonly:

   usage
   config
   plug

Resources:

* `Bug Tracker <http://github.com/getsentry/sentry-elixir/issues>`_
* `Github Project <http://github.com/getsentry/sentry-elixir>`_
