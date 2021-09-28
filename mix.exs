defmodule Sentry.Mixfile do
  use Mix.Project

  @version "8.0.6"
  @source_url "https://github.com/getsentry/sentry-elixir"

  def project do
    [
      app: :sentry,
      version: @version,
      elixir: "~> 1.10",
      description: "The Official Elixir client for Sentry",
      package: package(),
      deps: deps(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_core_path: "priv/plts",
        plt_add_deps: :app_tree,
        plt_add_apps: [:mix, :plug, :hackney]
      ],
      docs: [
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "#{@version}",
        source_url: @source_url,
        main: "readme",
        skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
      ],
      xref: [exclude: [:hackney, :hackney_pool, Plug.Conn]]
    ]
  end

  def application do
    [
      mod: {Sentry, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:hackney, "~> 1.8", optional: true},
      {:jason, "~> 1.1", optional: true},
      {:plug, "~> 1.6", optional: true},
      {:plug_cowboy, "~> 2.3", optional: true},
      {:dialyxir, "~> 1.0", only: [:test, :dev], runtime: false},
      {:ex_doc, "~> 0.23.0", only: :dev},
      {:bypass, "~> 2.0", only: [:test]},
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
