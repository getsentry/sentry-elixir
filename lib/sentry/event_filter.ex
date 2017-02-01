defmodule Sentry.EventFilter do
  @callback exclude_exception?(Exception.t, atom) :: any
end

defmodule Sentry.DefaultEventFilter do
  @behaviour Sentry.EventFilter
  def exclude_exception?(_, _), do: false
end
