import Config

if config_env() == :test do
  config :sentry,
    environment_name: :test,
    tags: %{},
    enable_source_code_context: true,
    root_source_code_paths: [File.cwd!()],
    hackney_opts: [recv_timeout: 50, pool: :sentry_pool],
    send_result: :sync,
    send_max_attempts: 1,
    dedup_events: false,
    test_mode: true

  config :logger, backends: []

  config :opentelemetry, span_processor: {Sentry.OpenTelemetry.SpanProcessor, []}

  config :opentelemetry,
    sampler: {Sentry.OpenTelemetry.Sampler, [drop: ["Elixir.Oban.Stager process"]]}
end

config :phoenix, :json_library, if(Code.ensure_loaded?(JSON), do: JSON, else: Jason)
