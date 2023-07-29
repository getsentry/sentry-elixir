defmodule Sentry.DefaultEventFilter do
  @ignored_exceptions [
    Phoenix.NotAcceptableError,
    Phoenix.Router.NoRouteError,
    Plug.Conn.InvalidQueryError,
    Plug.Parsers.BadEncodingError,
    Plug.Parsers.ParseError,
    Plug.Parsers.RequestTooLarge,
    Plug.Parsers.UnsupportedMediaTypeError,
    Plug.Static.InvalidPathError
  ]

  @moduledoc """
  The default implementation of the `Sentry.EventFilter` behaviour.

  This filter excludes the following exceptions:

  #{Enum.map_join(@ignored_exceptions, "\n", &"  * `#{inspect(&1)}`")}

  In addition, it excludes routes that do not match in plug routers.
  """

  @behaviour Sentry.EventFilter

  @impl true
  def exclude_exception?(%x{}, :plug) when x in @ignored_exceptions, do: true
  def exclude_exception?(%FunctionClauseError{function: :do_match, arity: 4}, :plug), do: true
  def exclude_exception?(_, _), do: false
end
