defmodule Sentry.Mixfile do
  use Mix.Project

  @version "10.6.1"
  @source_url "https://github.com/getsentry/sentry-elixir"

  def project do
    [
      app: :sentry,
      version: @version,
      elixir: "~> 1.11",
      description: "The Official Elixir client for Sentry",
      package: package(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        flags: [:unmatched_returns, :error_handling, :extra_return],
        plt_file: {:no_warn, "plts/dialyzer.plt"},
        plt_core_path: "plts",
        plt_add_deps: :app_tree,
        plt_add_apps: [:mix, :ex_unit]
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        "coveralls.html": :test
      ],
      name: "Sentry",
      docs: [
        extra_section: "Guides",
        extras: [
          "README.md",
          "CHANGELOG.md",
          "pages/setup-with-plug-and-phoenix.md",
          "pages/oban-integration.md",
          "pages/quantum-integration.md",
          "pages/upgrade-8.x.md",
          "pages/upgrade-9.x.md",
          "pages/upgrade-10.x.md"
        ],
        groups_for_extras: [
          Integrations: [
            "pages/setup-with-plug-and-phoenix.md",
            "pages/oban-integration.md",
            "pages/quantum-integration.md"
          ],
          "Upgrade Guides": [~r{^pages/upgrade}]
        ],
        groups_for_modules: [
          "Plug and Phoenix": [Sentry.PlugCapture, Sentry.PlugContext, Sentry.LiveViewHook],
          Loggers: [Sentry.LoggerBackend, Sentry.LoggerHandler],
          "Data Structures": [Sentry.Attachment, Sentry.CheckIn],
          HTTP: [Sentry.HTTPClient, Sentry.HackneyClient],
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
      xref: [exclude: [:hackney, :hackney_pool, Plug.Conn, :telemetry]],
      aliases: [aliases()]
    ]
  end

  def application do
    [
      mod: {Sentry.Application, []},
      extra_applications: [:logger],
      registered: [
        Sentry.Dedupe,
        Sentry.Transport.SenderRegistry,
        Sentry.Supervisor
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["test/support"] ++ elixirc_paths(:dev)
  defp elixirc_paths(_other), do: ["lib"]

  defp deps do
    [
      {:nimble_options, "~> 1.0"},
      {:nimble_ownership, "~> 0.3.0"},

      # Optional dependencies
      {:hackney, "~> 1.8", optional: true},
      {:jason, "~> 1.1", optional: true},
      {:phoenix, "~> 1.6", optional: true},
      {:phoenix_live_view, "~> 0.20", optional: true},
      {:plug, "~> 1.6", optional: true},
      {:telemetry, "~> 0.4 or ~> 1.0", optional: true},

      # Dev and test dependencies
      {:bypass, "~> 2.0", only: [:test]},
      {:dialyxir, "~> 1.0", only: [:test, :dev], runtime: false},
      {:ex_doc, "~> 0.29.0", only: :dev},
      {:excoveralls, "~> 0.17.1", only: [:test]},
      # Required by Phoenix.LiveView's testing
      {:floki, ">= 0.30.0", only: :test},
      {:oban, "~> 2.17 and >= 2.17.6", only: [:test]},
      {:quantum, "~> 3.0", only: [:test]}
    ]
  end

  defp package do
    [
      files: ["lib", "LICENSE", "mix.exs", "README.md", "CHANGELOG.md"],
      maintainers: ["Mitchell Henke", "Jason Stiebs"],
      licenses: ["MIT"],
      links: %{
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md",
        "GitHub" => @source_url
      }
    ]
  end

  defp aliases do
    [test: ["sentry.package_source_code", "test"]]
  end
end
