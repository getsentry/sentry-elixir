defmodule Sentry.Mixfile do
  use Mix.Project

  def project do
    [
      app: :sentry,
      version: "7.2.2",
      elixir: "~> 1.7",
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
      extra_applications: extra_applications(Mix.env())
    ]
  end

  defp deps do
    [
      {:hackney, "~> 1.8 or 1.6.5"},
      {:jason, "~> 1.1", optional: true},
      {:plug, "~> 1.6", optional: true},
      {:plug_cowboy, "~> 1.0 or ~> 2.0", optional: true},
      {:phoenix, "~> 1.3", optional: true},
      {:dialyxir, "> 0.0.0", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.21.0", only: :dev},
      {:bypass, "~> 1.0", only: [:test]}
    ]
  end

  defp package do
    [
      files: ["lib", "LICENSE", "mix.exs", "README.md"],
      maintainers: ["Mitchell Henke", "Jason Stiebs"],
      licenses: ["MIT"],
      links: %{
        "github" => "https://github.com/getsentry/sentry-elixir"
      }
    ]
  end

  defp elixirc_paths(_), do: ["lib"]

  defp extra_applications(:test) do
    [:telemetry, :logger]
  end

  defp extra_applications(_) do
    [:logger]
  end
end
