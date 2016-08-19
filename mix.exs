defmodule Sentry.Mixfile do
  use Mix.Project

  def project do
    [
      app: :sentry,
      name: :sentry_elixir,
      version: "0.0.5",
      elixir: "~> 1.3",
      description: "An Elixir client for Sentry",
      package: package(),
      deps: deps(),
      docs: [extras: ["README.md"], main: "README"]
    ]
  end

  def application do
    [
      applications: [:hackney, :uuid, :poison, :logger]
    ]
  end

  defp deps do
    [
      {:hackney, "~> 1.6.1"},
      {:uuid, "~> 1.0"},
      {:poison, "~> 1.5 or ~> 2.0"},

      {:ex_doc, "~> 0.13.0", only: :dev},
      {:credo, "~> 0.4", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      files: ["lib", "LICENSE", "mix.exs", "README.md"],
      contributors: ["Stanislav Vishnevskiy", "Mitchell Henke", "Jason Stiebs"],
      licenses: ["MIT"],
      links: %{
        "github" => "https://github.com/getsentry/sentry_elixir"
      }
    ]
  end
end
