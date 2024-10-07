defmodule Sentry.DataCategory do
  alias Sentry.CheckIn
  alias Sentry.Attachment
  alias Sentry.ClientReport
  alias Sentry.Event

  @spec data_category_mapping(
          Attachment.t()
          | CheckIn.t()
          | ClientReport.t()
          | Event.t()
          | String.t()
        ) ::
          String.t()
  def data_category_mapping(type) do
    if is_binary(type) do
      type
    else
      case type do
        %Attachment{} ->
          "attachment"

        %CheckIn{} ->
          "monitor"

        %ClientReport{} ->
          "internal"

        %Event{} ->
          "error"

        _ ->
          "default"
      end
    end

    # Other types Sentry Elixir does not support yet. When adding a new event item type, update this file too.
    # "session" -> "session"
    # "sessions" -> "session"
    # "transaction" -> "transaction"
    # "profile" -> "profile"
    # "span" -> "span"
    # "statsd" -> "metric_bucket"
    # "metric_meta" -> "metric_bucket"
  end
end
