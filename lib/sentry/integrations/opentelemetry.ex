defmodule Sentry.Integrations.Opentelemetry do
  @moduledoc false

  alias Sentry.Config

  def setup do
    if Config.dsn() do
      Application.put_env(:opentelemetry, :traces_exporter, :otlp)
      Application.put_env(:opentelemetry_exporter, :otlp_protocol, :http_protobuf)
      Application.put_env(:opentelemetry_exporter, :otlp_traces_endpoint, Config.spans_endpoint())
      Application.put_env(:opentelemetry_exporter, :otlp_headers, Config.auth_headers())
    end

    :ok
  end
end
