defmodule Sentry.Mixfile do
  use Mix.Project

  def project do
    [
      app: :sentry,
      version: "6.1.0",
      elixir: "~> 1.3",
      description: "The Official Elixir client for Sentry",
      package: package(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_deps: :transitive, plt_add_apps: [:mix]],
      docs: [extras: ["README.md"], main: "readme"]
    ]
  end

  def application do
    [
      mod: {Sentry, []},
      applications: [:hackney, :uuid, :poison, :logger]
    ]
  end

  defp deps do
    [
      {:hackney, "~> 1.8 or 1.6.5"},
      {:uuid, "~> 1.0"},
      {:poison, "~> 1.5 or ~> 2.0 or ~> 3.0"},
      {:plug, "~> 1.0", optional: true},
      {:dialyxir, "> 0.0.0", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.18.0", only: :dev},
      {:credo, "~> 0.8", only: [:dev, :test], runtime: false},
      {:bypass, "~> 0.8.0", only: [:test]}
    ]
  end

  defp package do
    [
      files: ["lib", "LICENSE", "mix.exs", "README.md"],
      maintainers: ["Stanislav Vishnevskiy", "Mitchell Henke", "Jason Stiebs"],
      licenses: ["MIT"],
      links: %{
        "github" => "https://github.com/getsentry/sentry-elixir"
      }
    ]
  end

  defp elixirc_paths(_), do: ["lib"]
end
