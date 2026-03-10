defmodule Sentry.OpenTelemetry.SetupTest do
  use Sentry.Case, async: false

  import ExUnit.CaptureLog
  import Sentry.TestHelpers

  alias Sentry.OpenTelemetry.Setup

  describe "maybe_configure_otel_sdk/1" do
    test "warns when OTel already started and span_processor not configured" do
      prev = Application.get_env(:opentelemetry, :span_processor)
      Application.delete_env(:opentelemetry, :span_processor)
      Application.delete_env(:opentelemetry, :processors)

      on_exit(fn ->
        if prev, do: Application.put_env(:opentelemetry, :span_processor, prev)
      end)

      log =
        capture_log(fn ->
          Setup.maybe_configure_otel_sdk([])
        end)

      assert log =~ "Cannot auto-configure span processor"
    end

    test "does not warn when span_processor is already configured" do
      prev = Application.get_env(:opentelemetry, :span_processor)

      Application.put_env(
        :opentelemetry,
        :span_processor,
        {Sentry.OpenTelemetry.SpanProcessor, []}
      )

      on_exit(fn ->
        if prev do
          Application.put_env(:opentelemetry, :span_processor, prev)
        else
          Application.delete_env(:opentelemetry, :span_processor)
        end
      end)

      log =
        capture_log(fn ->
          Setup.maybe_configure_otel_sdk([])
        end)

      refute log =~ "span processor"
    end

    test "does not warn when processors key is set" do
      prev_processor = Application.get_env(:opentelemetry, :span_processor)
      prev_processors = Application.get_env(:opentelemetry, :processors)
      Application.delete_env(:opentelemetry, :span_processor)
      Application.put_env(:opentelemetry, :processors, [{:otel_batch_processor, %{}}])

      on_exit(fn ->
        if prev_processor,
          do: Application.put_env(:opentelemetry, :span_processor, prev_processor)

        if prev_processors do
          Application.put_env(:opentelemetry, :processors, prev_processors)
        else
          Application.delete_env(:opentelemetry, :processors)
        end
      end)

      log =
        capture_log(fn ->
          Setup.maybe_configure_otel_sdk([])
        end)

      refute log =~ "span processor"
    end

    test "warns when OTel already started and sampler not configured" do
      prev = Application.get_env(:opentelemetry, :sampler)
      Application.delete_env(:opentelemetry, :sampler)

      on_exit(fn ->
        if prev, do: Application.put_env(:opentelemetry, :sampler, prev)
      end)

      log =
        capture_log(fn ->
          Setup.maybe_configure_otel_sdk(sampler_opts: [drop: ["test_span"]])
        end)

      assert log =~ "Cannot auto-configure sampler"
    end

    test "does not warn when sampler is already configured" do
      prev = Application.get_env(:opentelemetry, :sampler)
      Application.put_env(:opentelemetry, :sampler, {Sentry.OpenTelemetry.Sampler, []})

      on_exit(fn ->
        if prev do
          Application.put_env(:opentelemetry, :sampler, prev)
        else
          Application.delete_env(:opentelemetry, :sampler)
        end
      end)

      log =
        capture_log(fn ->
          Setup.maybe_configure_otel_sdk([])
        end)

      refute log =~ "sampler"
    end

    test "reconfigures propagators at runtime when OTel already started" do
      prev = Application.get_env(:opentelemetry, :text_map_propagators)
      Application.delete_env(:opentelemetry, :text_map_propagators)

      on_exit(fn ->
        if prev, do: Application.put_env(:opentelemetry, :text_map_propagators, prev)
      end)

      log =
        capture_log(fn ->
          Setup.maybe_configure_otel_sdk([])
        end)

      refute log =~ "propagator"
    end

    test "does not reconfigure propagators when already configured" do
      prev = Application.get_env(:opentelemetry, :text_map_propagators)
      custom = [:trace_context, :baggage]
      Application.put_env(:opentelemetry, :text_map_propagators, custom)

      on_exit(fn ->
        if prev do
          Application.put_env(:opentelemetry, :text_map_propagators, prev)
        else
          Application.delete_env(:opentelemetry, :text_map_propagators)
        end
      end)

      Setup.maybe_configure_otel_sdk([])

      assert Application.get_env(:opentelemetry, :text_map_propagators) == custom
    end

    test "skips all configuration when auto_setup is false" do
      prev_processor = Application.get_env(:opentelemetry, :span_processor)
      prev_sampler = Application.get_env(:opentelemetry, :sampler)
      prev_propagators = Application.get_env(:opentelemetry, :text_map_propagators)
      Application.delete_env(:opentelemetry, :span_processor)
      Application.delete_env(:opentelemetry, :processors)
      Application.delete_env(:opentelemetry, :sampler)
      Application.delete_env(:opentelemetry, :text_map_propagators)

      on_exit(fn ->
        if prev_processor,
          do: Application.put_env(:opentelemetry, :span_processor, prev_processor)

        if prev_sampler, do: Application.put_env(:opentelemetry, :sampler, prev_sampler)

        if prev_propagators,
          do: Application.put_env(:opentelemetry, :text_map_propagators, prev_propagators)
      end)

      log =
        capture_log(fn ->
          Setup.maybe_configure_otel_sdk(auto_setup: false)
        end)

      refute log =~ "span processor"
      refute log =~ "sampler"
      refute log =~ "propagator"
    end
  end

  describe "maybe_setup_instrumentations/1" do
    test "skips instrumentations that are set to false" do
      assert :ok =
               Setup.maybe_setup_instrumentations(
                 live_view: false,
                 bandit: false,
                 cowboy: false,
                 phoenix: false,
                 oban: false,
                 ecto: false,
                 logger_metadata: false
               )
    end

    test "handles unavailable modules gracefully" do
      assert :ok = Setup.maybe_setup_instrumentations([])
    end

    test "respects ecto disabled by default" do
      assert :ok = Setup.maybe_setup_instrumentations([])
    end
  end

  describe "config validation" do
    test "accepts valid opentelemetry integration config" do
      put_test_config(
        integrations: [
          opentelemetry: [
            auto_setup: true,
            sampler_opts: [drop: ["test"]],
            phoenix: [adapter: :bandit],
            bandit: true,
            cowboy: false,
            oban: true,
            ecto: [repos: [[:my_app, :repo]]],
            live_view: true,
            logger_metadata: false
          ]
        ]
      )

      config = Sentry.Config.integrations()
      otel_config = Keyword.get(config, :opentelemetry, [])

      assert Keyword.get(otel_config, :auto_setup) == true
      assert Keyword.get(otel_config, :sampler_opts) == [drop: ["test"]]
      assert Keyword.get(otel_config, :phoenix) == [adapter: :bandit]
      assert Keyword.get(otel_config, :cowboy) == false
      assert Keyword.get(otel_config, :ecto) == [repos: [[:my_app, :repo]]]
      assert Keyword.get(otel_config, :logger_metadata) == false
    end

    test "uses correct defaults for opentelemetry config" do
      put_test_config(integrations: [opentelemetry: []])

      config = Sentry.Config.integrations()
      otel_config = Keyword.get(config, :opentelemetry, [])

      assert Keyword.get(otel_config, :auto_setup) == true
      assert Keyword.get(otel_config, :sampler_opts) == []
      assert Keyword.get(otel_config, :phoenix) == true
      assert Keyword.get(otel_config, :bandit) == true
      assert Keyword.get(otel_config, :cowboy) == true
      assert Keyword.get(otel_config, :oban) == true
      assert Keyword.get(otel_config, :ecto) == false
      assert Keyword.get(otel_config, :live_view) == true
      assert Keyword.get(otel_config, :logger_metadata) == true
    end

    test "rejects invalid opentelemetry config" do
      assert_raise ArgumentError, ~r/invalid value for :auto_setup/, fn ->
        put_test_config(integrations: [opentelemetry: [auto_setup: "yes"]])
      end
    end
  end
end
