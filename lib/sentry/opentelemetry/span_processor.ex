if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
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

    # This can be a no-op since we can postpone inserting the span into storage until on_end
    @impl :otel_span_processor
    def on_start(_ctx, otel_span, _config) do
      otel_span
    end

    @impl :otel_span_processor
    def on_end(otel_span, _config) do
      span_record = SpanRecord.new(otel_span)

      SpanStorage.store_span(span_record)

      # Check if this is a root span (no parent) or a transaction root (HTTP server request span)
      # HTTP server request spans should be treated as transaction roots even when they have
      # an external parent span ID (from distributed tracing)
      is_transaction_root =
        span_record.parent_span_id == nil or
          is_http_server_request_span?(span_record) or
          is_live_view_server_span?(span_record)

      if is_transaction_root do
        child_span_records =
          span_record.span_id
          |> SpanStorage.get_child_spans()
          |> maybe_add_remote_children(span_record)

        transaction = build_transaction(span_record, child_span_records)

        result =
          case Sentry.send_transaction(transaction) do
            {:ok, _id} ->
              true

            :ignored ->
              true

            :excluded ->
              true

            {:error, error} ->
              Logger.warning("Failed to send transaction to Sentry: #{inspect(error)}")
              {:error, :invalid_span}
          end

        # Clean up: remove the transaction root span and all its children
        # Note: For distributed tracing, the transaction root span may have been stored
        # as a child span (with a remote parent_span_id). In that case, we need to also
        # remove it from the child spans, not just look for it as a root span.
        :ok = SpanStorage.remove_root_span(span_record.span_id)

        if span_record.parent_span_id != nil do
          # This span was stored as a child because it has a remote parent (distributed tracing).
          # We need to explicitly remove it from the child spans storage.
          :ok = SpanStorage.remove_child_span(span_record.parent_span_id, span_record.span_id)
        end

        result
      else
        true
      end
    end

    @impl :otel_span_processor
    def force_flush(_config) do
      :ok
    end

    # Helper function to detect if a span represents an HTTP server request
    # that should be treated as a transaction root for distributed tracing
    defp is_http_server_request_span?(%{kind: kind, attributes: attributes}) do
      kind == :server and
        Map.has_key?(attributes, to_string(HTTPAttributes.http_request_method()))
    end

    defp is_live_view_server_span?(%{kind: :server, origin: origin, name: name})
         when origin in ["opentelemetry_phoenix", :opentelemetry_phoenix] do
      String.ends_with?(name, ".mount") or
        String.contains?(name, ".handle_params") or
        String.contains?(name, ".handle_event")
    end

    defp is_live_view_server_span?(_span_record), do: false

    defp maybe_add_remote_children(child_span_records, %{parent_span_id: nil}) do
      child_span_records
    end

    defp maybe_add_remote_children(child_span_records, span_record) do
      if is_live_view_server_span?(span_record) do
        existing_ids = MapSet.new(child_span_records, & &1.span_id)

        adopted_children =
          span_record.parent_span_id
          |> SpanStorage.get_child_spans()
          |> Enum.filter(&eligible_for_adoption?(&1, span_record, existing_ids))
          |> Enum.map(&%{&1 | parent_span_id: span_record.span_id})

        Enum.each(adopted_children, fn child ->
          :ok = SpanStorage.remove_child_span(span_record.parent_span_id, child.span_id)
        end)

        child_span_records ++ adopted_children
      else
        child_span_records
      end
    end

    defp eligible_for_adoption?(child, span_record, existing_ids) do
      not MapSet.member?(existing_ids, child.span_id) and
        child.parent_span_id == span_record.parent_span_id and
        child.trace_id == span_record.trace_id and
        child.kind != :server and
        occurs_within_span?(child, span_record)
    end

    defp occurs_within_span?(child, parent) do
      with {:ok, parent_start} <- parse_datetime(parent.start_time),
           {:ok, parent_end} <- parse_datetime(parent.end_time),
           {:ok, child_start} <- parse_datetime(child.start_time),
           {:ok, child_end} <- parse_datetime(child.end_time) do
        DateTime.compare(child_start, parent_start) != :lt and
          DateTime.compare(child_end, parent_end) != :gt
      else
        _ -> true
      end
    end

    defp parse_datetime(nil), do: :error

    defp parse_datetime(timestamp) do
      case DateTime.from_iso8601(timestamp) do
        {:ok, datetime, _offset} -> {:ok, datetime}
        {:error, _} -> :error
      end
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
          trace: build_trace_context(root_span_record)
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
        data: filter_attributes(span_record.attributes)
      }
    end

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

      filtered_attributes = filter_attributes(span_record.attributes)

      %Span{
        op: op,
        description: description,
        start_timestamp: span_record.start_time,
        timestamp: span_record.end_time,
        trace_id: span_record.trace_id,
        span_id: span_record.span_id,
        parent_span_id: span_record.parent_span_id,
        origin: span_record.origin,
        data: Map.put(filtered_attributes, "otel.kind", span_record.kind),
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

    defp filter_attributes(attributes) do
      attributes
      |> Enum.reject(fn {key, value} ->
        case {key, value} do
          {"db.url", "ecto:"} -> true
          {"db.url", nil} -> true
          {"db.url", ""} -> true
          _ -> false
        end
      end)
      |> Map.new()
    end
  end
end
