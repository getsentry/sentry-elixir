defmodule Raven.Mixfile do
  use Mix.Project

  def project do
    [
      app: :raven,
      version: "0.0.4",
      elixir: "~> 1.0",
      description: "Raven is an Elixir client for Sentry",
      package: package,
      deps: deps
    ]
  end

  def application do
    applications = [:httpoison, :uuid, :poison]
    if Mix.env == :test, do: applications = [:logger|applications]
    [
      applications: applications
    ]
  end

  defp deps do
    [
      {:httpoison, "~> 0.4.2"},
      {:uuid, "~> 0.1.5"},
      {:poison, "~> 1.1.1"}
    ]
  end
  
  defp package do
    [
      files: ["lib", "LICENSE", "mix.exs", "README.md"],
      contributors: ["Stanislav Vishnevskiy"],
      licenses: ["MIT"],
      links: [{"github", "https://github.com/vishnevskiy/raven-elixir"}]
    ]
  end
end
