if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
  defmodule Sentry.OpenTelemetry.SpanProcessor do
    @moduledoc false

    @behaviour :otel_span_processor

    alias OpenTelemetry.SemConv.ClientAttributes, as: ClientAttributes
    require OpenTelemetry.SemConv.Incubating.DBAttributes, as: DBAttributes
    require OpenTelemetry.SemConv.Incubating.HTTPAttributes, as: HTTPAttributes
    alias OpenTelemetry.SemConv.Incubating.URLAttributes, as: URLAttributes
    require OpenTelemetry.SemConv.Incubating.MessagingAttributes, as: MessagingAttributes

    alias Sentry.{ClientError, LoggerUtils}

    alias Sentry.{Transaction, OpenTelemetry.SpanStorage, OpenTelemetry.SpanRecord}
    alias Sentry.Interfaces.Span

    @impl :otel_span_processor
    def on_start(ctx, otel_span, _config) do
      otel_span = mark_parent_is_remote(ctx, otel_span)

      span_record = SpanRecord.new(otel_span)
      SpanStorage.store_span(span_record)
      otel_span
    end

    if SpanRecord.parent_is_remote_on_record?() do
      defp mark_parent_is_remote(_ctx, otel_span), do: otel_span
    else
      # Older opentelemetry releases don't carry parent_span_is_remote on the
      # span record, but the parent's span context always knows whether it came
      # off the wire. Recording it as an attribute here is the only point where
      # that context is still reachable; SpanRecord strips it again so it never
      # reaches a reported payload.
      require Record

      Record.defrecordp(
        :span_ctx,
        Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
      )

      Record.defrecordp(
        :otel_span_rec,
        Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
      )

      defp mark_parent_is_remote(ctx, otel_span) do
        case :otel_tracer.current_span_ctx(ctx) do
          span_ctx(is_remote: true) ->
            attributes =
              :otel_attributes.set(
                %{SpanRecord.parent_is_remote_attribute() => true},
                otel_span_rec(otel_span, :attributes)
              )

            otel_span_rec(otel_span, attributes: attributes)

          _ ->
            otel_span
        end
      end
    end

    @impl :otel_span_processor
    def on_end(otel_span, _config) do
      span_record = SpanRecord.new(otel_span)
      SpanStorage.update_span(span_record)

      process_span(span_record)
    end

    @impl :otel_span_processor
    def force_flush(_config) do
      :ok
    end

    defp process_span(span_record) do
      cond do
        # Already reported as part of its parent's transaction (it finished
        # while that transaction was being sent) - don't report it twice
        SpanStorage.span_sent?(span_record.span_id) ->
          true

        # No parent = definitely a root
        span_record.parent_span_id == nil ->
          build_and_send_transaction(span_record)

        # The parent's transaction was already sent, so this span cannot be
        # attached to it anymore - report it as a follow-up transaction of
        # the same trace instead
        SpanStorage.span_sent?(span_record.parent_span_id) ->
          build_and_send_transaction(span_record, parent_already_sent?: true)

        # Parent exists locally - this is a child span, not a transaction root
        has_local_parent_span?(span_record.parent_span_id) ->
          true

        # A remote parent never appears in this node's storage, so this span is
        # the local root of a trace continued from elsewhere. Must stay below
        # the local-parent check: OTel copies the parent's span_ctx into every
        # child, so is_remote stays true for the whole local subtree - checked
        # any earlier, every span in the trace becomes its own transaction.
        # Compared to true explicitly because the field is :undefined for
        # parentless spans, which is truthy.
        span_record.parent_span_is_remote == true ->
          build_and_send_transaction(span_record)

        # Parent is remote (distributed tracing) - treat server spans as
        # transaction roots
        server_span?(span_record) ->
          build_and_send_transaction(span_record)

        true ->
          LoggerUtils.debug(fn ->
            "Discarding span #{span_record.name} (#{span_record.span_id}): its parent " <>
              "#{span_record.parent_span_id} is neither in span storage nor recently sent, " <>
              "so there is no transaction to attach it to"
          end)

          true
      end
    end

    defp has_local_parent_span?(parent_span_id) do
      SpanStorage.span_exists?(parent_span_id)
    end

    # Check if it's an HTTP server request span, a LiveView span, or an Oban consumer span
    defp server_span?(%{kind: :server} = span_record) do
      http_server_span?(span_record) or liveview_span?(span_record)
    end

    defp server_span?(%{kind: :consumer} = span_record) do
      oban_consumer_span?(span_record)
    end

    defp server_span?(_), do: false

    defp http_server_span?(%{kind: :server, attributes: attributes}) do
      Map.has_key?(attributes, to_string(HTTPAttributes.http_request_method()))
    end

    # Check if span name matches LiveView lifecycle patterns
    defp liveview_span?(%{origin: "opentelemetry_phoenix"}), do: true
    defp liveview_span?(_), do: false

    defp oban_consumer_span?(%{kind: :consumer, attributes: attributes}) do
      Map.get(attributes, to_string(MessagingAttributes.messaging_system())) == :oban
    end

    defp build_and_send_transaction(span_record, opts \\ []) do
      # Children still running when the root ends are excluded from the
      # payload: a reported span must have an end timestamp. Their records
      # stay in storage until they finish.
      child_span_records =
        span_record.span_id
        |> SpanStorage.get_child_spans()
        |> Enum.filter(& &1.end_time)

      transaction = build_transaction(span_record, child_span_records, opts)

      # Every span of the transaction gets a marker - late spans may continue
      # the trace from any of them, not just the root. Markers must precede
      # the send: a span ending while the send is in flight must already see
      # its parent as sent to be promoted. They record that the transaction
      # was finalized locally - not that delivery succeeded - since once the
      # records are removed below, later spans can never be attached to this
      # transaction either way.
      sent_span_ids = [span_record.span_id | Enum.map(child_span_records, & &1.span_id)]
      :ok = SpanStorage.mark_spans_sent(sent_span_ids)

      result =
        case Sentry.send_transaction(transaction) do
          {:ok, _id} ->
            true

          :ignored ->
            true

          :excluded ->
            true

          {:error, %ClientError{reason: :rate_limited} = error} ->
            LoggerUtils.debug(fn ->
              "Failed to send transaction to Sentry: #{inspect(error)}"
            end)

            {:error, :invalid_span}

          {:error, error} ->
            LoggerUtils.log(fn -> "Failed to send transaction to Sentry: #{inspect(error)}" end)
            {:error, :invalid_span}
        end

      :ok =
        SpanStorage.remove_transaction_root_span(
          span_record.span_id,
          span_record.parent_span_id
        )

      result
    end

    defp build_transaction(root_span_record, child_span_records, opts) do
      root_span = build_span(root_span_record)
      child_spans = Enum.map(child_span_records, &build_span(&1))

      Transaction.new(%{
        span_id: root_span.span_id,
        transaction: transaction_name(root_span_record),
        transaction_info: %{source: :custom},
        start_timestamp: root_span_record.start_time,
        timestamp: root_span_record.end_time,
        contexts: %{
          trace: build_trace_context(root_span_record, opts)
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

    defp build_trace_context(span_record, opts) do
      {op, description} = get_op_description(span_record)

      data = filter_attributes(span_record.attributes)

      data =
        if Keyword.get(opts, :parent_already_sent?, false) do
          Map.put(data, "sentry.parent_span_already_sent", true)
        else
          data
        end

      context = %{
        trace_id: span_record.trace_id,
        span_id: span_record.span_id,
        parent_span_id: span_record.parent_span_id,
        op: op,
        description: description,
        origin: span_record.origin,
        data: data
      }

      # Add links if present (for root spans, links go in trace context)
      if span_record.links != [] do
        Map.put(context, :links, format_links(span_record.links))
      else
        context
      end
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

      span = %Span{
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

      # Add links if present (for child spans, links go in the span itself).
      # When links is empty, the span retains links: nil (struct default), which is
      # consistent with how other optional Span fields (status, tags, op) are handled —
      # they are also sent as null via Map.from_struct/1 in Transaction.to_payload/1.
      if span_record.links != [] do
        %{span | links: format_links(span_record.links)}
      else
        span
      end
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

    # Format span links according to Sentry spec
    # https://develop.sentry.dev/sdk/telemetry/traces/span-links/
    #
    # Note: The spec defines an optional `sampled` boolean, but the OTel link record
    # only exposes `tracestate` (vendor key-value pairs), not `trace_flags` (which
    # contains the sampled bit). The sampled field cannot be extracted from the
    # current OTel Erlang SDK link record structure.
    defp format_links(links) do
      Enum.map(links, fn link ->
        formatted = %{
          span_id: link.span_id,
          trace_id: link.trace_id
        }

        # Add attributes if present
        if map_size(link.attributes) > 0 do
          Map.put(formatted, :attributes, link.attributes)
        else
          formatted
        end
      end)
    end
  end
end
