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
    require Record

    alias Sentry.{Transaction, OpenTelemetry.SpanStorage, OpenTelemetry.SpanRecord}
    alias Sentry.Interfaces.Span

    # Extract span record fields to access parent_span_id in on_start
    @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
    Record.defrecordp(:span, @span_fields)

    @impl :otel_span_processor
    def on_start(_ctx, otel_span, _config) do
      # Check if this is a LiveView span during static render
      # If so, mark it so we can filter it out in on_end
      if liveview_propagator_loaded?() and
           Sentry.OpenTelemetry.LiveViewPropagator.static_render?() do
        # Set an attribute on the span to mark it as from static render
        :otel_span.set_attribute(otel_span, :"sentry.liveview.static_render", true)
      end

      # Track pending children: when a span starts with a parent, register it
      # as a pending child. This allows us to wait for all children when
      # the parent ends, solving the race condition where parent.on_end
      # is called before child.on_end.
      parent_span_id = span(otel_span, :parent_span_id)
      span_id = span(otel_span, :span_id)

      if parent_span_id != nil and parent_span_id != :undefined do
        parent_span_id_str = cast_span_id(parent_span_id)
        span_id_str = cast_span_id(span_id)

        if parent_span_id_str != nil and span_id_str != nil do
          SpanStorage.store_pending_child(parent_span_id_str, span_id_str)
        end
      end

      otel_span
    end

    @impl :otel_span_processor
    def on_end(otel_span, _config) do
      span_record = SpanRecord.new(otel_span)
      process_span(span_record)
    end

    # Check if the LiveViewPropagator module is loaded (only compiled when Phoenix.LiveView is available)
    defp liveview_propagator_loaded? do
      Code.ensure_loaded?(Sentry.OpenTelemetry.LiveViewPropagator)
    end

    defp process_span(span_record) do
      SpanStorage.store_span(span_record)

      # Check if this is a root span (no parent) or a transaction root
      #
      # A span should be a transaction root if:
      # 1. It has no parent (true root span)
      # 2. OR it's a server span with only a REMOTE parent (distributed tracing)
      #
      # A span should NOT be a transaction root if:
      # - It has a LOCAL parent (parent span exists in our SpanStorage)
      is_transaction_root =
        cond do
          # No parent = definitely a root
          span_record.parent_span_id == nil ->
            true

          # Has a parent - check if it's local or remote
          true ->
            has_local_parent = has_local_parent_span?(span_record.parent_span_id)

            if has_local_parent do
              # Parent exists locally - this is a child span, not a transaction root
              false
            else
              # Parent is remote (distributed tracing) - treat server spans as transaction roots
              is_server_span?(span_record)
            end
        end

      if is_transaction_root do
        build_and_send_transaction(span_record)
      else
        true
      end
    end

    defp has_local_parent_span?(parent_span_id) do
      casted_parent_span_id = cast_span_id(parent_span_id)
      SpanStorage.span_exists?(casted_parent_span_id)
    end

    defp build_and_send_transaction(span_record) do
      child_span_records = SpanStorage.get_child_spans(span_record.span_id)
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
      :ok = SpanStorage.remove_root_span(span_record.span_id)

      result
    end

    @impl :otel_span_processor
    def force_flush(_config) do
      :ok
    end

    # Helper function to detect if a span is a server span that should be
    # treated as a transaction root for distributed tracing.
    # This includes HTTP server request spans (have http.request.method attribute)
    defp is_server_span?(%{kind: :server, attributes: attributes}) do
      # Check if it's an HTTP server request span (has http.request.method)
      Map.has_key?(attributes, to_string(HTTPAttributes.http_request_method()))
    end

    defp is_server_span?(_), do: false

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

      # Try multiple attributes for the URL path
      url_path =
        Map.get(span_record.attributes, to_string(URLAttributes.url_path())) ||
          Map.get(span_record.attributes, "url.full") ||
          Map.get(span_record.attributes, "http.target") ||
          Map.get(span_record.attributes, "http.route") ||
          span_record.name

      # Build description with method and path
      description =
        case url_path do
          nil -> to_string(http_request_method)
          path -> "#{http_request_method} #{path}"
        end

      description =
        if client_address do
          "#{description} from #{client_address}"
        else
          description
        end

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

    defp cast_span_id(span_id) when is_binary(span_id) do
      span_id
    end

    defp cast_span_id(span_id) when is_integer(span_id) do
      Integer.to_string(span_id)
    end
  end
end
