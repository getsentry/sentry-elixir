if Code.ensure_loaded?(OpenTelemetry) do
  defmodule Sentry.OpenTelemetry.SpanProcessor do
    @moduledoc false

    @behaviour :otel_span_processor

    require OpenTelemetry.SemConv.ClientAttributes, as: ClientAttributes
    require OpenTelemetry.SemConv.Incubating.DBAttributes, as: DBAttributes
    require OpenTelemetry.SemConv.Incubating.HTTPAttributes, as: HTTPAttributes
    require OpenTelemetry.SemConv.Incubating.URLAttributes, as: URLAttributes
    require OpenTelemetry.SemConv.Incubating.MessagingAttributes, as: MessagingAttributes

    require Logger

    alias Sentry.{Transaction, OpenTelemetry.SpanStorage, OpenTelemetry.SpanRecord}
    alias Sentry.Interfaces.Span

    @impl true
    def on_start(_ctx, otel_span, _config) do
      span_record = SpanRecord.new(otel_span)

      SpanStorage.store_span(span_record)

      otel_span
    end

    @impl true
    def on_end(otel_span, _config) do
      span_record = SpanRecord.new(otel_span)

      SpanStorage.update_span(span_record)

      if span_record.parent_span_id == nil do
        root_span_record = SpanStorage.get_root_span(span_record.span_id)
        child_span_records = SpanStorage.get_child_spans(span_record.span_id)
        transaction = build_transaction(root_span_record, child_span_records)

        result =
          case Sentry.send_transaction(transaction) do
            {:ok, _id} ->
              true

            :ignored ->
              true

            {:error, error} ->
              Logger.error("Failed to send transaction to Sentry: #{inspect(error)}")
              {:error, :invalid_span}
          end

        :ok = SpanStorage.remove_root_span(span_record.span_id)

        result
      else
        true
      end
    end

    @impl true
    def force_flush(_config) do
      :ok
    end

    defp build_transaction(root_span_record, child_span_records) do
      root_span = build_span(root_span_record)
      child_spans = Enum.map(child_span_records, &build_span(&1))

      Transaction.new(%{
        span_id: root_span.span_id,
        transaction: transaction_name(root_span_record),
        transaction_info: %{source: :custom},
        start_timestamp: root_span_record.start_time,
        timestamp: root_span_record.end_time,
        contexts: %{
          trace: build_trace_context(root_span_record),
          otel: build_otel_context(root_span_record)
        },
        spans: child_spans
      })
    end

    defp transaction_name(
           %{attributes: %{unquote(to_string(MessagingAttributes.messaging_system())) => :oban}} =
             span_record
         ) do
      span_record.attributes["oban.job.worker"]
    end

    defp transaction_name(span_record), do: span_record.name

    defp build_trace_context(span_record) do
      {op, description} = get_op_description(span_record)

      %{
        trace_id: span_record.trace_id,
        span_id: span_record.span_id,
        parent_span_id: span_record.parent_span_id,
        op: op,
        description: description,
        origin: span_record.origin,
        data: span_record.attributes
      }
    end

    defp build_otel_context(span_record), do: span_record.attributes

    defp get_op_description(
           %{
             attributes: %{
               unquote(to_string(HTTPAttributes.http_request_method())) => http_request_method
             }
           } = span_record
         ) do
      op = "http.#{span_record.kind}"

      client_address =
        Map.get(span_record.attributes, to_string(ClientAttributes.client_address()))

      url_path = Map.get(span_record.attributes, to_string(URLAttributes.url_path()))

      description =
        to_string(http_request_method) <>
          ((client_address && " from #{client_address}") || "") <>
          ((url_path && " #{url_path}") || "")

      {op, description}
    end

    defp get_op_description(
           %{attributes: %{unquote(to_string(DBAttributes.db_system())) => _db_system}} =
             span_record
         ) do
      db_query_text = Map.get(span_record.attributes, "db.statement")

      {"db", db_query_text}
    end

    defp get_op_description(%{
           attributes:
             %{unquote(to_string(MessagingAttributes.messaging_system())) => :oban} = attributes
         }) do
      {"queue.process", attributes["oban.job.worker"]}
    end

    defp get_op_description(span_record) do
      {span_record.name, span_record.name}
    end

    defp build_span(span_record) do
      {op, description} = get_op_description(span_record)

      %Span{
        op: op,
        description: description,
        start_timestamp: span_record.start_time,
        timestamp: span_record.end_time,
        trace_id: span_record.trace_id,
        span_id: span_record.span_id,
        parent_span_id: span_record.parent_span_id,
        origin: span_record.origin,
        data: Map.put(span_record.attributes, "otel.kind", span_record.kind),
        status: span_status(span_record)
      }
    end

    defp span_status(%{
           attributes: %{
             unquote(to_string(HTTPAttributes.http_response_status_code())) =>
               http_response_status_code
           }
         }) do
      to_status(http_response_status_code)
    end

    defp span_status(_span_record), do: nil

    # WebSocket upgrade spans doesn't have a HTTP status
    defp to_status(nil), do: nil

    defp to_status(status) when status in 200..299, do: "ok"

    for {status, string} <- %{
          400 => "invalid_argument",
          401 => "unauthenticated",
          403 => "permission_denied",
          404 => "not_found",
          409 => "already_exists",
          429 => "resource_exhausted",
          499 => "cancelled",
          500 => "internal_error",
          501 => "unimplemented",
          503 => "unavailable",
          504 => "deadline_exceeded"
        } do
      defp to_status(unquote(status)), do: unquote(string)
    end

    defp to_status(_any), do: "unknown_error"
  end
end
