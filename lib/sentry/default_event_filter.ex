defmodule Sentry.DefaultEventFilter do
  @behaviour Sentry.EventFilter

  @moduledoc false

  def exclude_exception?(_, _), do: false
end
