defmodule Sentry.Opentelemetry.SpanProcessor do
  @behaviour :otel_span_processor

  alias Sentry.{Span, Transaction, Opentelemetry.SpanStorage, Opentelemetry.SpanRecord}

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
      root_span = SpanStorage.get_root_span(span_record.span_id)
      child_spans = SpanStorage.get_child_spans(span_record.span_id)

      transaction = build_transaction(root_span, child_spans)

      Sentry.send_transaction(transaction)
    end

    :ok
  end

  @impl true
  def force_flush(_config) do
    :ok
  end

  defp build_transaction(%SpanRecord{origin: :undefined} = root_span, child_spans) do
    Transaction.new(%{
      transaction: root_span.name,
      start_timestamp: root_span.start_time,
      timestamp: root_span.end_time,
      contexts: %{
        trace: build_trace_context(root_span)
      },
      spans: Enum.map([root_span | child_spans], &build_span(&1))
    })
  end

  defp build_transaction(%SpanRecord{origin: "opentelemetry_ecto"} = root_span, child_spans) do
    Transaction.new(%{
      transaction: root_span.name,
      start_timestamp: root_span.start_time,
      timestamp: root_span.end_time,
      transaction_info: %{
        source: "component"
      },
      contexts: %{
        trace: build_trace_context(root_span)
      },
      data: root_span.attributes,
      measurements: %{},
      spans: Enum.map(child_spans, &build_span(&1))
    })
  end

  defp build_transaction(
         %SpanRecord{attributes: attributes, origin: "opentelemetry_phoenix"} = root_span,
         child_spans
       ) do
    Transaction.new(%{
      transaction: "#{attributes["phoenix.plug"]}##{attributes["phoenix.action"]}",
      start_timestamp: root_span.start_time,
      timestamp: root_span.end_time,
      transaction_info: %{
        source: "view"
      },
      contexts: %{
        trace: build_trace_context(root_span)
      },
      request: %{
        url: attributes["http.target"],
        method: attributes["http.method"],
        headers: %{
          "User-Agent" => attributes["http.user_agent"]
        },
        env: %{
          "SERVER_NAME" => attributes["net.host.name"],
          "SERVER_PORT" => attributes["net.host.port"]
        }
      },
      data: %{
        "http.response.status_code" => attributes["http.status_code"],
        "method" => attributes["http.method"],
        "path" => attributes["http.target"],
        "params" => %{
          "controller" => attributes["phoenix.plug"],
          "action" => attributes["phoenix.action"]
        }
      },
      measurements: %{},
      spans: Enum.map(child_spans, &build_span(&1))
    })
  end

  defp build_transaction(
         %SpanRecord{attributes: attributes, origin: "opentelemetry_bandit"} = root_span,
         child_spans
       ) do
    Transaction.new(%{
      start_timestamp: root_span.start_time,
      timestamp: root_span.end_time,
      transaction: attributes["http.target"],
      transaction_info: %{
        source: "url"
      },
      contexts: %{
        trace: build_trace_context(root_span)
      },
      request: %{
        url: attributes["http.url"],
        method: attributes["http.method"],
        headers: %{
          "User-Agent" => attributes["http.user_agent"]
        },
        env: %{
          "SERVER_NAME" => attributes["net.peer.name"],
          "SERVER_PORT" => attributes["net.peer.port"]
        }
      },
      measurements: %{},
      spans: Enum.map(child_spans, &build_span(&1))
    })
  end

  defp build_trace_context(
         %SpanRecord{origin: "opentelemetry_phoenix", attributes: attributes} = root_span
       ) do
    %{
      trace_id: root_span.trace_id,
      span_id: root_span.span_id,
      parent_span_id: nil,
      op: "http.server",
      origin: root_span.origin,
      data: %{
        "http.response.status_code" => attributes["http.status_code"]
      }
    }
  end

  defp build_trace_context(
         %SpanRecord{origin: "opentelemetry_ecto", attributes: attributes} = root_span
       ) do
    %{
      trace_id: root_span.trace_id,
      span_id: root_span.span_id,
      parent_span_id: root_span.parent_span_id,
      op: "db.#{attributes["db.type"]}.ecto",
      description: attributes["db.statement"] || root_span.name,
      origin: root_span.origin,
      data: attributes
    }
  end

  defp build_trace_context(%SpanRecord{attributes: attributes} = root_span) do
    %{
      trace_id: root_span.trace_id,
      span_id: root_span.span_id,
      parent_span_id: nil,
      op: root_span.name,
      origin: root_span.origin,
      data: attributes
    }
  end

  defp build_span(
         %SpanRecord{origin: "opentelemetry_phoenix", attributes: attributes} = span_record
       ) do
    op = "#{attributes["phoenix.plug"]}##{attributes["phoenix.action"]}"

    %Span{
      op: op,
      start_timestamp: span_record.start_time,
      timestamp: span_record.end_time,
      trace_id: span_record.trace_id,
      span_id: span_record.span_id,
      parent_span_id: span_record.parent_span_id,
      description: attributes["http.route"],
      origin: span_record.origin
    }
  end

  defp build_span(%SpanRecord{origin: "phoenix_app"} = span_record) do
    %Span{
      trace_id: span_record.trace_id,
      op: span_record.name,
      start_timestamp: span_record.start_time,
      timestamp: span_record.end_time,
      span_id: span_record.span_id,
      parent_span_id: span_record.parent_span_id
    }
  end

  defp build_span(%SpanRecord{origin: "opentelemetry_bandit"} = span_record) do
    %Span{
      trace_id: span_record.trace_id,
      op: span_record.name,
      start_timestamp: span_record.start_time,
      timestamp: span_record.end_time,
      span_id: span_record.span_id,
      parent_span_id: span_record.parent_span_id,
      description: span_record.name,
      origin: span_record.origin
    }
  end

  defp build_span(%SpanRecord{origin: "opentelemetry_ecto", attributes: attributes} = span_record) do
    %Span{
      trace_id: span_record.trace_id,
      span_id: span_record.span_id,
      parent_span_id: span_record.parent_span_id,
      op: "db.#{attributes["db.type"]}.ecto",
      description: attributes["db.statement"] || span_record.name,
      origin: span_record.origin,
      start_timestamp: span_record.start_time,
      timestamp: span_record.end_time,
      data: attributes
    }
  end

  defp build_span(%SpanRecord{origin: :undefined, attributes: _attributes} = span_record) do
    %Span{
      trace_id: span_record.trace_id,
      op: span_record.name,
      start_timestamp: span_record.start_time,
      timestamp: span_record.end_time,
      span_id: span_record.span_id,
      parent_span_id: span_record.parent_span_id
    }
  end
end
