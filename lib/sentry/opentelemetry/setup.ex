if Sentry.OpenTelemetry.VersionChecker.tracing_compatible?() do
  defmodule Sentry.OpenTelemetry.Setup do
    @moduledoc false

    require Logger

    @doc """
    Configures the OpenTelemetry SDK with Sentry's span processor, sampler, and propagator.

    Called during `Sentry.Application.start/2`, before the supervisor starts.
    Only applies configuration if the user hasn't already configured it via
    `config :opentelemetry` entries.
    """
    @spec maybe_configure_otel_sdk(keyword()) :: :ok
    def maybe_configure_otel_sdk(otel_config) do
      unless Keyword.get(otel_config, :auto_setup) == false do
        maybe_set_span_processor()
        maybe_set_sampler(Keyword.get(otel_config, :sampler_opts, []))
        maybe_set_propagators()
      end

      :ok
    end

    @doc """
    Auto-detects and sets up available instrumentation libraries.

    Called after the Sentry supervisor starts. Respects per-instrumentation config
    to enable/disable individual libraries.
    """
    @spec maybe_setup_instrumentations(keyword()) :: :ok
    def maybe_setup_instrumentations(otel_config) do
      # Order matters: LiveView propagator MUST come before Phoenix
      maybe_setup(:live_view, otel_config, fn _opts ->
        setup_if_available(Sentry.OpenTelemetry.LiveViewPropagator, :setup, [])
      end)

      maybe_setup(:bandit, otel_config, fn _opts ->
        setup_if_available(OpentelemetryBandit, :setup, [])
      end)

      maybe_setup(:cowboy, otel_config, fn _opts ->
        setup_if_available(OpentelemetryCowboy, :setup, [])
      end)

      maybe_setup(:phoenix, otel_config, fn opts ->
        if Code.ensure_loaded?(OpentelemetryPhoenix) do
          opts = if opts == [], do: detect_phoenix_adapter_opts(), else: opts
          apply(OpentelemetryPhoenix, :setup, [opts])
        end
      end)

      maybe_setup(:oban, otel_config, fn _opts ->
        setup_if_available(OpentelemetryOban, :setup, [])
      end)

      maybe_setup(:ecto, otel_config, fn opts ->
        repos = Keyword.get(opts, :repos, [])
        ecto_opts = Keyword.drop(opts, [:repos])

        for repo <- repos do
          setup_if_available(OpentelemetryEcto, :setup, [repo, ecto_opts])
        end
      end)

      maybe_setup(:logger_metadata, otel_config, fn _opts ->
        setup_if_available(OpentelemetryLoggerMetadata, :setup, [])
      end)

      :ok
    end

    # OTel SDK configuration

    defp maybe_set_span_processor do
      if Application.get_env(:opentelemetry, :span_processor) == nil and
           Application.get_env(:opentelemetry, :processors) == nil do
        if otel_started?() do
          Logger.warning(
            "[Sentry] OpenTelemetry has already started. " <>
              "Cannot auto-configure span processor. " <>
              "Add `config :opentelemetry, span_processor: {Sentry.OpenTelemetry.SpanProcessor, []}` " <>
              "to your config or ensure :sentry starts before :opentelemetry."
          )
        else
          Application.put_env(
            :opentelemetry,
            :span_processor,
            {Sentry.OpenTelemetry.SpanProcessor, []}
          )
        end
      end
    end

    defp maybe_set_sampler(sampler_opts) do
      if Application.get_env(:opentelemetry, :sampler) == nil do
        if otel_started?() do
          Logger.warning(
            "[Sentry] OpenTelemetry has already started. " <>
              "Cannot auto-configure sampler. " <>
              "Add `config :opentelemetry, sampler: {Sentry.OpenTelemetry.Sampler, #{inspect(sampler_opts)}}` " <>
              "to your config or ensure :sentry starts before :opentelemetry."
          )
        else
          Application.put_env(
            :opentelemetry,
            :sampler,
            {Sentry.OpenTelemetry.Sampler, sampler_opts}
          )
        end
      end
    end

    defp maybe_set_propagators do
      if Application.get_env(:opentelemetry, :text_map_propagators) == nil do
        propagators = [:trace_context, :baggage, Sentry.OpenTelemetry.Propagator]

        if otel_started?() do
          # Propagators can be reconfigured at runtime
          composite = :otel_propagator_text_map_composite.create(propagators)
          :opentelemetry.set_text_map_propagator(composite)
        else
          Application.put_env(:opentelemetry, :text_map_propagators, propagators)
        end
      end
    end

    # Instrumentation setup helpers

    defp maybe_setup(key, otel_config, setup_fn) do
      config_value = Keyword.get(otel_config, key, default_for(key))

      unless config_value == false do
        opts = if is_list(config_value), do: config_value, else: []

        try do
          setup_fn.(opts)
        rescue
          e ->
            Logger.warning(
              "[Sentry] Failed to auto-setup #{key} instrumentation: #{Exception.message(e)}"
            )
        end
      end
    end

    defp setup_if_available(module, function, args) do
      if Code.ensure_loaded?(module) do
        apply(module, function, args)
      end
    end

    defp detect_phoenix_adapter_opts do
      cond do
        Code.ensure_loaded?(Bandit) -> [adapter: :bandit]
        Code.ensure_loaded?(:cowboy) -> [adapter: :cowboy2]
        true -> []
      end
    end

    defp default_for(:ecto), do: false
    defp default_for(_key), do: true

    defp otel_started? do
      case List.keyfind(Application.started_applications(), :opentelemetry, 0) do
        nil -> false
        _ -> true
      end
    end
  end
end
