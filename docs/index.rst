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

Edit your mix.exs file to add it as a dependency and add the `:sentry` package to your applications:

.. code-block:: elixir
  defp application do
   [applications: [:sentry, :logger]]
  end

  defp deps do
    [{:sentry, "~> 1.0"}]
  end

Configuration
-------------

Setup the application production environment in your `config/prod.exs`

.. code-block:: elixir
  config :sentry,
    dsn: "https://public:secret@app.getsentry.com/1",
    tags: %{
      env: "production"
      },
    included_environments: ~w(prod)

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
```

Deep Dive
---------

Want more?  Have a look at the full documentation for more information.

.. toctree::
   :maxdepth: 2
   :titlesonly:

   usage
   config
   integrations/index

Resources:

* `Bug Tracker <http://github.com/getsentry/sentry-elixir/issues>`_
* `Github Project <http://github.com/getsentry/sentry-elixir>`_
