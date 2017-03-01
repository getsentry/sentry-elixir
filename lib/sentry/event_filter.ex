defmodule Sentry.EventFilter do
  @moduledoc """

  """

  @callback exclude_exception?(Exception.t, atom) :: any
end

defmodule Sentry.DefaultEventFilter do
  @behaviour Sentry.EventFilter

  @moduledoc false

  def exclude_exception?(_, _), do: false
end
