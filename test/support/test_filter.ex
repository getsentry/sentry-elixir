defmodule Sentry.TestFilter do
  @behaviour Sentry.EventFilter

  def exclude_exception?(%ArithmeticError{}, :plug), do: true
  def exclude_exception?(_, _), do: false
end
