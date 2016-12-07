defmodule Sentry.TestFilter do
  @behaviour Sentry.Filter

  def exclude_exception?(%ArithmeticError{}, :plug), do: true
  def exclude_exception?(_, _), do: false
end
