Usage
=====

To use simply follow the :doc:`installation guide <installation>`.

Capturing Errors
----------------

If you use the error logger and setup Plug/Phoenix then you are already done, all errors will bubble up to 
sentry.

Otherwise we provide a simple way to capture exceptions:

.. code-block:: elixir
  do
    ThisWillError.reall()
  rescue
    my_exception ->
      Sentry.capture_exception(my_exception, [stacktrace: System.stacktrace(), extra: %{extra: information}])
  end


Optional Attributes -------------------

With calls to ``capture_exception`` additional data can be supplied as a keyword list:

  .. code-block:: elixir

      Sentry.capture_exception(ex, opts)

.. describe:: extra

    Additional context for this event. Must be a mapping. Children can be any native JSON type.

    .. code-block:: elixir

        extra: %{key: "value"}

.. describe:: level

    The level of the event. Defaults to ``error``.

    .. code-block:: elixir
        
         level: "warning"

    Sentry is aware of the following levels:

    * debug (the least serious)
    * info
    * warning
    * error
    * fatal (the most serious)

.. describe:: tags

    Tags to index with this event. Must be a mapping of strings.

    .. code-block:: elixir

        tags: %{"key" => "value"}

.. describe:: user

    The acting user.

    .. code-block:: elixir
        
        user: %{
            "id" => 42,
            "email" => "clever-girl"
        }


Breadcrumbs
-----------

Sentry supports capturing breadcrumbs -- events that happened prior to an issue. We need to be careful because
breadcrumbs are per-process, if a process dies it might lose its context.

.. code-block:: elixir
  Sentry.Context.add_breadcrumb(%{my: "crumb"})



Filtering Out Errors
--------------------

