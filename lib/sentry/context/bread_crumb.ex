defmodule Sentry.Context.BreadCrumb do

  defstruct data: nil,
    category: nil,
    message: nil,
    level: nil,
    timestamp: nil

  @type t :: %Sentry.Context.BreadCrumb{
    data: %{} | nil,
    category: binary() | nil,
    message: binary() | nil,
    level: :error | :warning | :info | :debug | nil,
    timestamp: binary() | nil
  }
end
