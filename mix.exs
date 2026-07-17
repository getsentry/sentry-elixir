defmodule Sentry.Mixfile do
  use Mix.Project

  @version "13.3.0"
  @source_url "https://github.com/getsentry/sentry-elixir"

  def project do
    [
      app: :sentry,
      version: @version,
      elixir: "~> 1.13",
      lockfile: lockfile(current_elixir_version()),
      description: "The Official Elixir client for Sentry",
      package: package(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: test_paths(System.get_env("SENTRY_INTEGRATION")),
      test_ignore_filters: [~r|/fixtures/|],
      dialyzer: [
        flags: [:unmatched_returns, :error_handling, :extra_return],
        plt_file: {:no_warn, "plts/dialyzer.plt"},
        plt_core_path: "plts",
        plt_add_deps: :app_tree,
        plt_add_apps: [:mix, :ex_unit]
      ],
      test_coverage: [tool: ExCoveralls],
      name: "Sentry",
      docs: [
        extra_section: "Guides",
        extras: [
          "README.md",
          "CHANGELOG.md",
          "pages/setup-with-plug-and-phoenix.md",
          "pages/oban-integration.md",
          "pages/quantum-integration.md",
          "pages/telemetry-integration.md",
          "pages/upgrade-8.x.md",
          "pages/upgrade-9.x.md",
          "pages/upgrade-10.x.md"
        ],
        groups_for_extras: [
          Integrations: [
            "pages/setup-with-plug-and-phoenix.md",
            "pages/oban-integration.md",
            "pages/quantum-integration.md",
            "pages/telemetry-integration.md"
          ],
          "Upgrade Guides": [~r{^pages/upgrade}]
        ],
        groups_for_modules: [
          "Plug and Phoenix": [Sentry.PlugCapture, Sentry.PlugContext, Sentry.LiveViewHook],
          Loggers: [Sentry.LoggerBackend, Sentry.LoggerHandler],
          "Data Structures": [Sentry.Attachment, Sentry.CheckIn, Sentry.ClientReport],
          HTTP: [Sentry.HTTPClient, Sentry.FinchClient, Sentry.HackneyClient],
          Interfaces: [~r/^Sentry\.Interfaces/],
          Testing: [Sentry.Test]
        ],
        source_ref: "#{@version}",
        source_url: @source_url,
        main: "readme",
        logo: "assets/logo.png",
        skip_undefined_reference_warnings_on: [
          "CHANGELOG.md",
          "pages/upgrade-9.x.md"
        ],
        authors: ["Mitchell Henke", "Jason Stiebs", "Andrea Leopardi"]
      ],
      aliases: aliases()
    ] ++ xref_options()
  end

  defp xref_options do
    if Version.match?(System.version(), ">= 1.20.0") do
      [
        elixirc_options: [
          no_warn_undefined: [
            Finch,
            :hackney,
            :hackney_pool,
            Plug.Conn,
            :telemetry,
            :otel_tracer,
            :otel_span
          ]
        ]
      ]
    else
      [
        xref: [
          exclude: [
            Finch,
            :hackney,
            :hackney_pool,
            Plug.Conn,
            :telemetry,
            :otel_tracer,
            :otel_span
          ]
        ]
      ]
    end
  end

  def application do
    [
      mod: {Sentry.Application, []},
      extra_applications: extra_applications(Mix.env()),
      registered: [
        Sentry.Dedupe,
        Sentry.Transport.SenderRegistry,
        Sentry.Supervisor
      ]
    ]
  end

  def cli do
    [preferred_envs: ["coveralls.html": :test, "test.integrations": :test]]
  end

  defp extra_applications(:test), do: [:logger, :opentelemetry]
  defp extra_applications(_other), do: [:logger]

  defp elixirc_paths(:test), do: ["test/support"] ++ elixirc_paths(:dev)
  defp elixirc_paths(_other), do: ["lib"]

  defp test_paths(nil), do: ["test"]
  defp test_paths(integration), do: ["test_integrations/#{integration}/test"]

  defp deps do
    [
      {:nimble_options, "~> 1.0"},
      # This is only needed by `Sentry.Test`
      {:nimble_ownership, "~> 1.0"},

      # Optional dependencies
      {:hackney, ">= 1.8.0 and < 5.0.0", optional: true},
      {:finch, "~> 0.21", optional: true},
      {:jason, "~> 1.1", optional: true},
      {:phoenix, "~> 1.6", optional: true},
      {:phoenix_live_view, "~> 0.20 or ~> 1.0", optional: true},
      {:plug, dep_version(:plug, current_elixir_version()), optional: true},
      {:telemetry, "~> 0.4 or ~> 1.0", optional: true},
      {:igniter, dep_version(:igniter, current_elixir_version()), optional: true},
      {:rewrite, dep_version(:rewrite, current_elixir_version()), optional: true},

      # Dev and test dependencies
      {:plug_cowboy, "~> 2.7", only: [:test]},
      {:bandit, dep_version(:bandit, current_elixir_version()), only: [:test]},
      {:bypass, "~> 2.0", only: [:test]},
      {:dialyxir, "~> 1.0", only: [:test, :dev], runtime: false},
      {:ex_doc, "~> 0.29", only: :dev},
      {:excoveralls, "~> 0.17.1", only: [:test]},
      # Required by Phoenix.LiveView's testing
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:oban, "~> 2.17 and >= 2.17.6", only: [:test]},
      {:quantum, "~> 3.0", only: [:test]},

      # Optional dependencies for Sentry.OpenTelemetry - we allow any version
      # because the actual version requirements are verified via VersionChecker.
      # This is to allow users install `sentry` even when they rely on opentelemetry
      # libs that are too old for Sentry tracing feature.
      {:opentelemetry, ">= 0.0.0", optional: true},
      {:opentelemetry_api, ">= 0.0.0", optional: true},
      {:opentelemetry_exporter, ">= 0.0.0", optional: true},
      {:opentelemetry_semantic_conventions, ">= 0.0.0", optional: true},
      {:opentelemetry_logger_metadata, "~> 0.2.0", only: :test}
    ] ++ logger_backends_dep() ++ ex_ast_dep(current_elixir_version())
  end

  # ex_ast >= 0.12.1 (pulled in transitively via igniter >= 0.8) requires
  # Elixir ~> 1.19, which breaks Elixir 1.18 - pin the last compatible release.
  defp ex_ast_dep(%Version{major: 1, minor: 18}),
    do: [{:ex_ast, ">= 0.12.0 and < 0.12.1", optional: true}]

  defp ex_ast_dep(%Version{}), do: []

  # This will go away when we remove `LoggerBackend` in `14.0.0`
  defp logger_backends_dep do
    if Version.match?(System.version(), ">= 1.15.0") do
      [{:logger_backends, "~> 1.0", only: [:test]}]
    else
      []
    end
  end

  # Plug >= 1.19 starts Plug.Upload under a PartitionSupervisor, which only
  # exists on Elixir 1.14+.
  defp dep_version(:plug, %Version{major: 1, minor: minor}) when minor < 14,
    do: "~> 1.6 and < 1.19.0"

  defp dep_version(:plug, %Version{}), do: "~> 1.6"

  # Igniter >= 0.6.4 requires Elixir ~> 1.15.
  defp dep_version(:igniter, %Version{major: 1, minor: minor}) when minor < 15,
    do: "~> 0.6.3 and < 0.6.4"

  defp dep_version(:igniter, %Version{major: 1, minor: minor}) when minor < 18,
    do: "~> 0.7.9 and < 0.8.0"

  defp dep_version(:igniter, %Version{}), do: "~> 0.5"

  # Rewrite >= 1.2 requires Elixir ~> 1.15.
  defp dep_version(:rewrite, %Version{major: 1, minor: minor}) when minor < 15,
    do: "~> 1.1.0"

  defp dep_version(:rewrite, %Version{}), do: ">= 1.1.1 and < 2.0.0-0"

  # Bandit >= 1.12 uses Elixir 1.15-only syntax.
  defp dep_version(:bandit, %Version{major: 1, minor: minor}) when minor < 15,
    do: ">= 1.0.0 and < 1.12.0"

  defp dep_version(:bandit, %Version{}), do: "~> 1.0"

  defp current_elixir_version, do: Version.parse!(System.version())

  defp lockfile(%Version{major: 1, minor: minor}) when minor < 15,
    do: "mix-1.13-1.14.lock"

  defp lockfile(%Version{major: 1, minor: minor}) when minor < 18,
    do: "mix-1.15-1.17.lock"

  # ex_ast (see ex_ast_dep/1) forces a dedicated lockfile for 1.18: newer
  # ex_ast releases required by later Elixir versions don't support it.
  defp lockfile(%Version{major: 1, minor: 18}), do: "mix-1.18.lock"

  defp lockfile(%Version{}), do: "mix.lock"

  defp package do
    [
      files: [
        "lib",
        "LICENSE",
        "mix.exs",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "ISSUE_TEMPLATE.md",
        "README.md"
      ],
      maintainers: ["Mitchell Henke", "Jason Stiebs"],
      licenses: ["MIT"],
      links: %{
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md",
        "GitHub" => @source_url
      }
    ]
  end

  defp aliases do
    [
      test: ["sentry.package_source_code", "test"],
      "test.integrations": &run_integration_tests_if_supported/1
    ]
  end

  defp run_integration_tests_if_supported(args) do
    run_integration_tests("prod_mode", args, env: [{"MIX_ENV", "prod"}])

    if Version.match?(System.version(), ">= 1.16.0") do
      run_integration_tests("umbrella", args)
      run_integration_tests("phoenix_app", args)
      run_integration_tests("legacy_otel", args)
    else
      Mix.shell().info("Skipping integration tests for Elixir versions < 1.16")
    end
  end

  defp run_integration_tests(integration, args, opts \\ []) do
    IO.puts(
      IO.ANSI.format([
        "\n",
        [:bright, :cyan, "==> Running tests for integration: #{integration}"]
      ])
    )

    case setup_integration(integration, opts) do
      {_, 0} ->
        color_arg = if IO.ANSI.enabled?(), do: "--color", else: "--no-color"

        {_, status} = run_in_integration(integration, ["test", color_arg | args], opts)

        if status > 0 do
          IO.puts(
            IO.ANSI.format([
              :red,
              "Integration tests for #{integration} failed"
            ])
          )

          System.at_exit(fn _ -> exit({:shutdown, 1}) end)
        else
          IO.puts(
            IO.ANSI.format([
              :green,
              "Integration tests for #{integration} passed"
            ])
          )
        end
    end
  end

  defp setup_integration(integration, opts) do
    deps_get_args =
      if Version.match?(System.version(), ">= 1.14.0"),
        do: ["deps.get", "--check-locked"],
        else: ["deps.get"]

    run_in_integration(integration, deps_get_args, opts)
  end

  defp run_in_integration(integration, args, opts) do
    cmd_opts = [
      into: IO.binstream(:stdio, :line),
      cd: Path.join("test_integrations", integration)
    ]

    cmd_opts =
      case Keyword.get(opts, :env) do
        nil -> cmd_opts
        env -> Keyword.put(cmd_opts, :env, env)
      end

    System.cmd("mix", args, cmd_opts)
  end
end
