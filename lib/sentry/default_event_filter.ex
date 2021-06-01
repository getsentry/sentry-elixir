defmodule Sentry.DefaultEventFilter do
  @behaviour Sentry.EventFilter

  @moduledoc false

  @ignored_exceptions [
    Phoenix.Router.NoRouteError,
    Plug.Parsers.RequestTooLargeError,
    Plug.Parsers.BadEncodingError,
    Plug.Parsers.ParseError,
    Plug.Parsers.UnsupportedMediaTypeError
  ]

  def exclude_exception?(%x{}, :plug) when x in @ignored_exceptions do
    true
  end

  def exclude_exception?(%FunctionClauseError{function: :do_match, arity: 4}, :plug), do: true

  def exclude_exception?(_, _), do: false
end
