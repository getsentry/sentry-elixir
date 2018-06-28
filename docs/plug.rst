Sentry.Plug
=============

Sentry.Plug provides basic functionality to handle Plug.ErrorHandler.

To capture errors, simply put the following in your router:

.. code-block:: elixir

  use Sentry.Plug

Optional settings
------------------

.. describe:: body_scrubber

  The function to call before sending the body of the request to Sentry.  It will default to ``Sentry.Plug.default_body_scrubber/1``, which will remove sensitive parameters like "password", "passwd", "secret", or any values resembling a credit card.

.. describe:: header_scrubber

  The function to call before sending the headers of the request to Sentry.  It will default to ``Sentry.Plug.default_header_scrubber/1``, which will remove "Authorization" and "Authentication" headers.

.. describe:: cookie_scrubber

  The function to call before sending the cookies in the request to Sentry.  It will default to ``Sentry.Plug.default_cookie_scrubber/1``, which removes all cookie information.

.. describe:: request_id_header

  If you're using Phoenix, Plug.RequestId, or another method to set a request ID response header, and would like to include that information with errors reported by Sentry.Plug, the `:request_id_header` option allows you to set which header key Sentry should check.  It will default to "x-request-id", which Plug.RequestId (and therefore Phoenix) also default to.
