defmodule Sentry.Mixfile do
  use Mix.Project

  @version "9.0.0"
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
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_core_path: "priv/plts",
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
          "pages/upgrade-8.x.md",
          "pages/upgrade-9.x.md"
        ],
        groups_for_extras: [
          "Upgrade Guides": [
            "pages/upgrade-8.x.md",
            "pages/upgrade-9.x.md"
          ]
        ],
        groups_for_modules: [
          "Plug and Phoenix": [Sentry.PlugCapture, Sentry.PlugContext],
          Loggers: [Sentry.LoggerBackend, Sentry.LoggerHandler],
          Interfaces: [~r/^Sentry\.Interfaces/]
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
      xref: [exclude: [:hackney, :hackney_pool, Plug.Conn]]
    ]
  end

  def application do
    [
      mod: {Sentry.Application, []},
      extra_applications: [:logger],
      registered: [
        Sentry.Transport.SenderRegistry,
        Sentry.Supervisor
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["test/support"] ++ elixirc_paths(:dev)
  defp elixirc_paths(_other), do: ["lib"]

  defp deps do
    [
      {:hackney, "~> 1.8", optional: true},
      {:jason, "~> 1.1", optional: true},
      {:plug, "~> 1.6", optional: true},
      {:plug_cowboy, "~> 2.3", optional: true},

      # Dev and test dependencies
      {:bypass, "~> 2.0", only: [:test]},
      {:dialyxir, "~> 1.0", only: [:test, :dev], runtime: false},
      {:ex_doc, "~> 0.29.0", only: :dev},
      {:excoveralls, "~> 0.17.1", only: [:test]},
      {:phoenix, "~> 1.5", only: [:test]},
      {:phoenix_html, "~> 2.0", only: [:test]}
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
end
