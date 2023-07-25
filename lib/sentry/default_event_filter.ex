defmodule Sentry.DefaultEventFilter do
  @behaviour Sentry.EventFilter

  @moduledoc false

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

  def exclude_exception?(%x{}, :plug) when x in @ignored_exceptions do
    true
  end

  def exclude_exception?(%FunctionClauseError{function: :do_match, arity: 4}, :plug), do: true

  def exclude_exception?(_, _), do: false
end
