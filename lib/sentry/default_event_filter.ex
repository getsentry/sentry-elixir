defmodule Sentry.DefaultEventFilter do
  @behaviour Sentry.EventFilter

  @moduledoc false

  def exclude_exception?(%x{}, :plug) when x in [Phoenix.Router.NoRouteError] do
    true
  end

  def exclude_exception?(%FunctionClauseError{function: :do_match, arity: 4}, :plug), do: true

  def exclude_exception?(_, _), do: false
end
