defmodule Sentry.OpenTelemetry.SpanRecordTest do
  use Sentry.Case, async: true

  alias Sentry.OpenTelemetry.SpanRecord

  describe "struct shape across supported opentelemetry versions" do
    test "always exposes parent_span_is_remote" do
      assert Map.has_key?(%SpanRecord{}, :parent_span_is_remote)
    end
  end
end
