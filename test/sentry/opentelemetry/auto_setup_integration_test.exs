defmodule Sentry.OpenTelemetry.AutoSetupIntegrationTest do
  use Sentry.Case, async: false

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  alias Sentry.OpenTelemetry.Setup

  setup do
    otel_keys = [:span_processor, :processors, :sampler, :text_map_propagators]

    saved =
      Map.new(otel_keys, fn key ->
        {key, Application.get_env(:opentelemetry, key)}
      end)

    on_exit(fn ->
      for {key, value} <- saved do
        if value do
          Application.put_env(:opentelemetry, key, value)
        else
          Application.delete_env(:opentelemetry, key)
        end
      end
    end)

    %{saved_otel_env: saved}
  end

  defp clear_otel_env do
    Application.delete_env(:opentelemetry, :span_processor)
    Application.delete_env(:opentelemetry, :processors)
    Application.delete_env(:opentelemetry, :sampler)
    Application.delete_env(:opentelemetry, :text_map_propagators)
  end

  describe "full auto-setup flow" do
    test "with default config, warns about OTel already started for processor/sampler" do
      clear_otel_env()

      log =
        capture_log(fn ->
          Setup.maybe_configure_otel_sdk([])
        end)

      assert log =~ "Cannot auto-configure span processor"
      assert log =~ "Cannot auto-configure sampler"

      refute log =~ "propagator"
    end

    test "with auto_setup: false, no OTel SDK configuration happens" do
      clear_otel_env()

      log =
        capture_log(fn ->
          Setup.maybe_configure_otel_sdk(auto_setup: false)
        end)

      assert log == ""
      assert Application.get_env(:opentelemetry, :span_processor) == nil
      assert Application.get_env(:opentelemetry, :sampler) == nil
      assert Application.get_env(:opentelemetry, :text_map_propagators) == nil
    end

    test "respects existing user configuration" do
      Application.put_env(
        :opentelemetry,
        :span_processor,
        {:otel_batch_processor, %{}}
      )

      Application.put_env(
        :opentelemetry,
        :sampler,
        {:parent_based, %{root: :always_on}}
      )

      Application.put_env(
        :opentelemetry,
        :text_map_propagators,
        [:trace_context, :baggage]
      )

      log =
        capture_log(fn ->
          Setup.maybe_configure_otel_sdk([])
        end)

      assert log == ""

      assert Application.get_env(:opentelemetry, :span_processor) ==
               {:otel_batch_processor, %{}}

      assert Application.get_env(:opentelemetry, :sampler) ==
               {:parent_based, %{root: :always_on}}

      assert Application.get_env(:opentelemetry, :text_map_propagators) ==
               [:trace_context, :baggage]
    end
  end

  describe "instrumentation auto-setup with config" do
    test "all instrumentations disabled via config" do
      config = [
        live_view: false,
        bandit: false,
        cowboy: false,
        phoenix: false,
        oban: false,
        ecto: false,
        logger_metadata: false
      ]

      assert :ok = Setup.maybe_setup_instrumentations(config)
    end

    test "default config enables available instrumentations gracefully" do
      assert :ok = Setup.maybe_setup_instrumentations([])
    end

    test "phoenix with keyword list options does not raise" do
      assert :ok = Setup.maybe_setup_instrumentations(phoenix: [adapter: :bandit])
    end

    test "ecto requires explicit repos config" do
      assert :ok = Setup.maybe_setup_instrumentations([])

      assert :ok = Setup.maybe_setup_instrumentations(ecto: [repos: []])
    end
  end

  describe "config-driven integration" do
    test "opentelemetry config is properly nested under integrations" do
      put_test_config(
        integrations: [
          opentelemetry: [
            auto_setup: false,
            sampler_opts: [drop: ["healthcheck"]],
            phoenix: [adapter: :bandit],
            ecto: [repos: [[:my_app, :repo]], db_statement: :enabled]
          ]
        ]
      )

      integrations = Sentry.Config.integrations()
      otel_config = Keyword.fetch!(integrations, :opentelemetry)

      assert Keyword.fetch!(otel_config, :auto_setup) == false
      assert Keyword.fetch!(otel_config, :sampler_opts) == [drop: ["healthcheck"]]
      assert Keyword.fetch!(otel_config, :phoenix) == [adapter: :bandit]

      assert Keyword.fetch!(otel_config, :ecto) == [
               repos: [[:my_app, :repo]],
               db_statement: :enabled
             ]

      assert Keyword.fetch!(otel_config, :bandit) == true
      assert Keyword.fetch!(otel_config, :oban) == true
      assert Keyword.fetch!(otel_config, :live_view) == true
    end

    test "empty opentelemetry config uses all defaults" do
      put_test_config(integrations: [opentelemetry: []])

      integrations = Sentry.Config.integrations()
      otel_config = Keyword.fetch!(integrations, :opentelemetry)

      assert Keyword.fetch!(otel_config, :auto_setup) == true
      assert Keyword.fetch!(otel_config, :ecto) == false
      assert Keyword.fetch!(otel_config, :phoenix) == true
    end

    test "omitting opentelemetry from integrations config uses defaults" do
      put_test_config(integrations: [])

      integrations = Sentry.Config.integrations()
      otel_config = Keyword.get(integrations, :opentelemetry)

      assert Keyword.fetch!(otel_config, :auto_setup) == true
      assert Keyword.fetch!(otel_config, :ecto) == false
    end

    test "Setup module is defined when tracing is compatible" do
      assert Code.ensure_loaded?(Sentry.OpenTelemetry.Setup)
    end
  end
end
